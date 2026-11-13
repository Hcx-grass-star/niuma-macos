import Foundation
import NiumaInstallation

/// 安装回归只操作临时目录内的真实签名应用包和示例配置。
let root = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-install-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

/// 断言失败时退出非零；不以源码匹配或模拟删除代替文件状态证据。
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "InstallationTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// 构造真正包含 Mach-O 执行文件及有效临时签名的测试应用，不启动或注册到系统。
func fixture(_ name: String, version: String, identifier: String = "com.niuma.installtest") throws -> URL {
    let app = root.appendingPathComponent(name + ".app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version, "CFBundleVersion": version, "CFBundleExecutable": "Test", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let binary = contents.appendingPathComponent("MacOS/Test")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", "--identifier", identifier, app.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run(); sign.waitUntilExit()
    try require(sign.terminationStatus == 0, "测试应用签名失败")
    return app
}

/// 读取安装后的真实 Info.plist 判断版本，避免仅检查内存中的计划。
func version(_ url: URL) throws -> String { try InstalledBundle(url: url, identifier: "com.niuma.installtest").version.text }

do {
    let settings = root.appendingPathComponent("settings.json")
    let wages = Data("{\"salary\":21000,\"workdays\":[1,2,3,4,5]}".utf8)
    try wages.write(to: settings)
    let old = try fixture("installed", version: "0.2.1")
    let new = try fixture("download", version: "0.3.0")
    let replacement = try BundleReplacement(source: new, destination: old, identifier: "com.niuma.installtest")
    try replacement.prepare()
    try require(try version(old) == "0.2.1", "复制准备期间不能删除旧版")
    try replacement.replace()
    try require(try version(old) == "0.3.0", "正式位置应替换为新版")
    try require(try version(new) == "0.3.0", "确认启动前不能清理下载源")
    let trash = root.appendingPathComponent("old-in-trash.app")
    try replacement.commit { try FileManager.default.moveItem(at: $0, to: trash) }
    try require(try version(trash) == "0.2.1", "提交后只回收旧包")
    try require(try Data(contentsOf: settings) == wages, "升级不能改动工资配置")
    print("PASS: 新版覆盖、旧包提交后回收、下载源及工资配置保留")

    let failedOld = try fixture("rollback-old", version: "0.2.1")
    let failed = try BundleReplacement(source: new, destination: failedOld, identifier: "com.niuma.installtest")
    try failed.prepare(); try failed.replace(); try failed.rollback()
    try require(try version(failedOld) == "0.2.1", "启动失败应恢复旧版")
    print("PASS: 新版启动失败后的真实文件回滚")

    let newer = try fixture("newer", version: "0.4.0")
    do {
        _ = try BundleReplacement(source: new, destination: newer, identifier: "com.niuma.installtest")
        throw InstallationError.invalidBundle
    } catch InstallationError.downgrade {}
    try require(try version(newer) == "0.4.0", "不能降级或删除已安装的更新版本")
    let other = try fixture("same-name-other-app", version: "0.1.0", identifier: "com.example.other")
    do {
        _ = try BundleReplacement(source: new, destination: other, identifier: "com.niuma.installtest")
        throw InstallationError.downgrade
    } catch InstallationError.invalidBundle {}
    try require(FileManager.default.fileExists(atPath: other.path), "同名其他应用必须保留")
    print("PASS: 拒绝降级和错误应用身份")

    let damaged = try fixture("damaged", version: "0.3.0")
    try Data("tampered".utf8).write(to: damaged.appendingPathComponent("Contents/extra.txt"))
    let untouched = try fixture("signature-old", version: "0.2.1")
    let invalid = try BundleReplacement(source: damaged, destination: untouched, identifier: "com.niuma.installtest")
    do { try invalid.prepare(); throw InstallationError.invalidBundle }
    catch InstallationError.signature {}
    try require(try version(untouched) == "0.2.1", "签名错误不能触碰旧包")
    let symlink = root.appendingPathComponent("alias.app")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: untouched)
    do { _ = try InstalledBundle(url: symlink, identifier: "com.niuma.installtest"); throw InstallationError.signature }
    catch InstallationError.invalidBundle {}
    print("PASS: 拒绝篡改包和符号链接；旧版不受影响")
    let token = UUID().uuidString
    let cleanupRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/niuma-cleaner-test-" + token)
    try FileManager.default.createDirectory(at: cleanupRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cleanupRoot) }
    let live = try fixture("live-" + token, version: "0.3.0", identifier: ManagedInstallation.identifier)
    let legacy = try fixture("legacy-" + token, version: "0.2.1", identifier: ManagedInstallation.identifier)
    let equal = try fixture("equal-" + token, version: "0.3.0", identifier: ManagedInstallation.identifier)
    let future = try fixture("future-" + token, version: "0.4.0", identifier: ManagedInstallation.identifier)
    var copies: [URL] = []
    for app in [legacy, equal, future, other] {
        let copy = cleanupRoot.appendingPathComponent(app.lastPathComponent)
        try FileManager.default.copyItem(at: app, to: copy)
        copies.append(copy)
    }
    try await ManagedInstallation.cleanup(current: InstalledBundle(url: live, identifier: ManagedInstallation.identifier), candidates: copies)
    try require(!FileManager.default.fileExists(atPath: copies[0].path), "必须回收旧副本")
    for copy in copies.dropFirst() { try require(FileManager.default.fileExists(atPath: copy.path), "同版本、较新版本和其他应用必须保留") }
    let recycled = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/" + legacy.lastPathComponent)
    if FileManager.default.fileExists(atPath: recycled.path) {
        _ = try InstalledBundle(url: recycled, identifier: ManagedInstallation.identifier)
        try FileManager.default.removeItem(at: recycled)
    }
    print("PASS: 真实旧副本回收；同版本、较新版本和其他应用保留；测试回收物已清理")
    print("全部安装文件集成验证通过。")
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
