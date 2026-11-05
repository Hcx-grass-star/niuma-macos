// swift-tools-version: 6.0
import PackageDescription

// 收入逻辑使用系统框架；原生自动更新固定使用 Sparkle，依赖锁定后可离线复用。
// 最低 macOS 13：覆盖 Ventura 及之后的系统，同时保留 SMAppService 登录项能力。
let package = Package(
    name: "Niuma",
    platforms: [.macOS("13.0")],
    products: [.executable(name: "Niuma", targets: ["Niuma"]), .executable(name: "NiumaInstaller", targets: ["NiumaInstaller"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "NiumaCore", resources: [.process("Resources")]),
        .target(name: "NiumaInstallation", dependencies: ["NiumaCore"]),
        .executableTarget(name: "NiumaInstaller", dependencies: ["NiumaInstallation"]),
        .executableTarget(name: "InstallationIntegrationTests", dependencies: ["NiumaInstallation"], path: "Tests/NiumaInstallationTests"),
        .executableTarget(name: "Niuma", dependencies: ["NiumaCore", "NiumaInstallation", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "NiumaIntegrationTests", dependencies: ["NiumaCore"], path: "Tests/NiumaCoreTests")
    ]
)
