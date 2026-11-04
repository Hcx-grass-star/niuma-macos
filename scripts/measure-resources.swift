import Foundation
import Darwin
import CoreGraphics

/// 一次非侵入式采样，仅记录资源指标，不读取应用工资或界面内容。
struct ResourceSample: Codable {
    /// 从开始采样起经过的秒数。
    let elapsedSeconds: Double
    /// 内核报告的 physical footprint，单位 MiB。
    let footprintMiB: Double
    /// 单核心满载为 100% 的区间 CPU 占用。
    let cpuPercent: Double
    /// 仅记录被测进程的可见内容窗口尺寸，识别面板意外收起的采样。
    let visibleSurfaces: [String]
}

/// 使用同一内核口径的短时基线报告，不自动声称完整验收通过。
struct ResourceReport: Codable {
    /// 被测进程编号。
    let pid: Int32
    /// 实际采样起点，便于对应构建和操作记录。
    let startedAt: Date
    /// 从被测进程实际应用包读取的源文件指纹。
    let sourceHash: String?
    /// 完整的采样点，保留峰值与波动信息。
    let samples: [ResourceSample]
    /// 采样窗口内的最大内存占用。
    let maxFootprintMiB: Double
    /// 按时间加权计算的窗口平均 CPU 占用。
    let averageCPUPercent: Double
    /// 内核记录的进程整个生命周期内存峰值，包含首次加载。
    let lifetimePeakFootprintMiB: Double
}

/// 通过系统公开 libproc 接口读取物理占用与累计 CPU 时间。
func usage(pid: Int32) throws -> rusage_info_v4 {
    var info = rusage_info_v4()
    let result = withUnsafeMutableBytes(of: &info) { bytes in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, bytes.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
    }
    guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return info
}

/// 只读取目标进程的窗口几何，不截屏、不读取其他应用标题或内容。
func visibleSurfaces(pid: Int32) -> [String] {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.compactMap { window in
        guard let owner = window[kCGWindowOwnerPID as String] as? Int32, owner == pid,
              let bounds = window[kCGWindowBounds as String] as? [String: Double],
              let width = bounds["Width"], let height = bounds["Height"], width > 100, height > 100 else { return nil }
        return String(Int(width)) + "x" + String(Int(height))
    }.sorted()
}

/// 测量指定进程的连续资源窗口，进程退出或输出失败时返回非零状态。
func measure() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 4, let pid = Int32(arguments[1]), let seconds = Int(arguments[2]), seconds > 0 else {
        throw NSError(domain: "NiumaResourceCheck", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "用法：swift scripts/measure-resources.swift <PID> <采样秒数> <报告路径>"])
    }
    let startedAt = Date()
    // libproc 的路径缓冲区上限为 4 * MAXPATHLEN，复合宏不能直接导入 Swift。
    var executablePath = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &executablePath, UInt32(executablePath.count)) > 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let executable = URL(fileURLWithPath: String(cString: executablePath))
    let bundle = Bundle(url: executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    let sourceHash = bundle?.object(forInfoDictionaryKey: "NiumaSourceHash") as? String
    let start = ProcessInfo.processInfo.systemUptime
    let first = try usage(pid: pid)
    var previous = first
    var previousTime = start
    var samples = [ResourceSample(elapsedSeconds: 0, footprintMiB: Double(first.ri_phys_footprint) / 1048576,
                                  cpuPercent: 0, visibleSurfaces: visibleSurfaces(pid: pid))]
    for _ in 0..<seconds {
        Thread.sleep(forTimeInterval: 1)
        let current = try usage(pid: pid)
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = Double(current.ri_user_time - previous.ri_user_time + current.ri_system_time - previous.ri_system_time)
            / 1_000_000_000 / (now - previousTime) * 100
        samples.append(ResourceSample(elapsedSeconds: now - start, footprintMiB: Double(current.ri_phys_footprint) / 1048576,
                                      cpuPercent: cpu, visibleSurfaces: visibleSurfaces(pid: pid)))
        previous = current
        previousTime = now
    }
    let cpuTotal = Double(previous.ri_user_time - first.ri_user_time + previous.ri_system_time - first.ri_system_time)
        / 1_000_000_000 / (previousTime - start) * 100
    let report = ResourceReport(pid: pid, startedAt: startedAt, sourceHash: sourceHash, samples: samples,
                                maxFootprintMiB: samples.map(\.footprintMiB).max()!, averageCPUPercent: cpuTotal,
                                lifetimePeakFootprintMiB: Double(previous.ri_lifetime_max_phys_footprint) / 1048576)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let destination = URL(fileURLWithPath: arguments[3])
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(report).write(to: destination, options: .atomic)
    print(String(format: "最大 physical footprint：%.2f MiB；平均 CPU：%.4f%%", report.maxFootprintMiB, report.averageCPUPercent))
    print("报告：" + destination.path)
}

do { try measure() }
catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
