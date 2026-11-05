import Foundation

/// 正式版本号，只接受三个非负整数段和可选的 v 前缀。
public struct UpdateVersion: Comparable, Sendable {
    /// 用于按数值比较的主、次、修订版本，避免将 0.10 排在 0.2 前面。
    private let components: [Int]
    /// 无前缀的展示版本。
    public let text: String

    /// 拒绝预发布、歧义前导零及无法精确表示的版本号。
    public init(_ raw: String) throws {
        let text = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw UpdateError.invalidRelease }
        let values = try parts.map { part -> Int in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || !part.hasPrefix("0"),
                  let value = Int(part), value <= 9007199254740991 else { throw UpdateError.invalidRelease }
            return value
        }
        self.text = text
        components = values
    }

    /// 主版本优先，其次比较次版本和修订版本。
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// 通过校验的新版说明及本仓库的正式发布页。
public struct UpdateRelease: Sendable {
    /// 正式版本号。
    public let version: String
    /// 以纯文本展示的更新说明。
    public let notes: String
    /// 用户点击后由系统浏览器打开的发布页。
    public let pageURL: URL
}

/// 区分可下载新版、已是最新版、未发布和缺少本平台安装包。
public enum UpdateResult: Sendable {
    case available(UpdateRelease), upToDate, unpublished, unavailable
}

/// 不依赖工资存储的自动检查限频规则。
public enum UpdatePolicy {
    /// 自动检查按尝试时间限频；失败和时钟回退也不进行密集重试。
    public static func shouldCheck(enabled: Bool, lastAttempt: Date?, now: Date) -> Bool {
        enabled && (lastAttempt.map { now.timeIntervalSince($0) >= 86400 } ?? true)
    }
}

/// 可展示的检查错误；不将工资配置写入错误消息。
public enum UpdateError: String, Error, LocalizedError {
    case invalidRelease = "发布信息无效，请稍后重试。"
    case rateLimited = "更新服务暂时受限，请稍后重试。"
    case network = "检查更新失败，请检查网络后重试。"
    /// 面向用户的简短中文说明。
    public var errorDescription: String? { rawValue }
}

/// 优先读取静态版本清单，失败后回退 GitHub API；只获取元数据，不安装程序。
public struct UpdateService: Sendable {
    /// 备用的公开正式发布接口，测试时可注入本地 HTTP 地址。
    public let endpoint: URL
    /// 静态主更新源；测试旧 API 时可置空，避免访问公网。
    public let manifestEndpoint: URL?
    /// 请求超时秒数。
    private let timeout: TimeInterval

    /// 注入独立主备来源和单源超时，正式应用优先访问静态托管清单。
    public init(endpoint: URL = URL(string: "https://api.github.com/repos/Hcx-grass-star/niuma-macos/releases/latest")!, manifestEndpoint: URL? = URL(string: "https://hcx-grass-star.github.io/niuma-macos/latest.json")!, timeout: TimeInterval = 10) {
        self.endpoint = endpoint
        self.manifestEndpoint = manifestEndpoint
        self.timeout = timeout
    }

    /// 主源有效时不请求 API；双源失败抛出备用源错误，不冒充已是最新版。
    public func check(currentVersion: String) async throws -> UpdateResult {
        let current = try UpdateVersion(currentVersion)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        if let manifestEndpoint {
            do {
                if let data = try await load(manifestEndpoint, session: session, current: current, isManifest: true) {
                    guard let manifest = try? JSONDecoder().decode(UpdateManifest.self, from: data) else { throw UpdateError.invalidRelease }
                    return try evaluate(manifest.release(), current: current)
                }
            } catch { /* 静态源缺失、超时或内容无效时，仅回退一次公开 API。 */ }
        }
        guard let data = try await load(endpoint, session: session, current: current, isManifest: false) else { return .unpublished }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else { throw UpdateError.invalidRelease }
        return try evaluate(release, current: current)
    }

    /// 对单个来源执行无缓存请求，限制响应大小并区分缺失、限流和网络失败。
    private func load(_ url: URL, session: URLSession, current: UpdateVersion, isManifest: Bool) async throws -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(isManifest ? "application/json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Niuma/" + current.text, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw UpdateError.network }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
        if http.statusCode == 404 { return nil }
        if [403, 429].contains(http.statusCode) { throw UpdateError.rateLimited }
        guard http.statusCode == 200 else { throw UpdateError.network }
        guard data.count <= 1_048_576 else { throw UpdateError.invalidRelease }
        return data
    }

    /// 两种来源共用正式版本、发布页、平台安装包和纯文本说明判定。
    private func evaluate(_ release: GitHubRelease, current: UpdateVersion) throws -> UpdateResult {
        if release.draft || release.prerelease { return .unpublished }
        let version = try UpdateVersion(release.tag_name)
        guard let url = URL(string: release.html_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path == "/Hcx-grass-star/niuma-macos/releases/tag/" + release.tag_name else { throw UpdateError.invalidRelease }
        guard version > current else { return .upToDate }
        guard release.assets.contains(where: { asset in
            let name = asset.name.lowercased()
            return name.hasSuffix(".dmg") || (name.contains("macos") && name.hasSuffix(".zip"))
        }) else { return .unavailable }
        return .available(UpdateRelease(version: version.text, notes: String((release.body ?? "暂无更新说明。").prefix(4000)), pageURL: url))
    }
}

/// 静态清单仅包含正式版本、说明、发布页及已上传的平台安装包地址。
private struct UpdateManifest: Decodable {
    /// 三段正式版本号，不接受预发布。
    let version: String
    /// 原样作为纯文本展示的说明。
    let notes: String?
    /// 可选的正式发布页；省略时使用 v 前缀标签。
    let url: String?
    /// 缺少 macOS 包时允许为空，不能提示下载 Windows 包。
    let macos: String?
    /// Windows 安装包仅用于与跨平台清单保持一致及验证来源。
    let windows: String?

    /// 转换为现有发布规则；下载地址必须属于本仓库且与清单版本一致。
    func release() throws -> GitHubRelease {
        let parsed = try UpdateVersion(version)
        let page = url ?? "https://github.com/Hcx-grass-star/niuma-macos/releases/tag/v" + parsed.text
        guard let pageURL = URL(string: page) else { throw UpdateError.invalidRelease }
        let tag = pageURL.lastPathComponent
        guard try UpdateVersion(tag) == parsed else { throw UpdateError.invalidRelease }
        let assets = try [asset(macos, tag: tag, platform: "macos"), asset(windows, tag: tag, platform: "windows")].compactMap { $0 }
        return GitHubRelease(tag_name: tag, body: notes, html_url: page, draft: false, prerelease: false, assets: assets)
    }

    /// 校验直接下载 URL 的仓库、标签、文件名及平台扩展名，不访问下载地址。
    private func asset(_ raw: String?, tag: String, platform: String) throws -> GitHubRelease.Asset? {
        guard let raw else { return nil }
        let prefix = "https://github.com/Hcx-grass-star/niuma-macos/releases/download/" + tag + "/"
        guard raw.hasPrefix(prefix), let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { throw UpdateError.invalidRelease }
        let file = String(raw.dropFirst(prefix.count))
        guard !file.isEmpty, let decoded = file.removingPercentEncoding, !decoded.contains("/"), !decoded.contains("\\") else { throw UpdateError.invalidRelease }
        let name = file.lowercased()
        let supported = platform == "macos" ? name.hasSuffix(".dmg") || (name.contains("macos") && name.hasSuffix(".zip")) : name.hasSuffix(".exe") || name.hasSuffix(".msi")
        guard supported else { throw UpdateError.invalidRelease }
        return GitHubRelease.Asset(name: file)
    }
}

/// GitHub 版本响应，只读取更新检查真正需要的字段。
private struct GitHubRelease: Decodable {
    /// Git 标签中的版本号。
    let tag_name: String
    /// 发布说明，允许为空。
    let body: String?
    /// 发布页地址。
    let html_url: String
    /// 草稿禁止用于更新提示。
    let draft: Bool
    /// 预发布禁止用于正式更新提示。
    let prerelease: Bool
    /// 可用安装包，用于筛选 macOS 版本。
    let assets: [Asset]

    /// 发布资产，仅需要名称识别支持的平台。
    struct Asset: Decodable {
        /// 安装包文件名。
        let name: String
    }
}
