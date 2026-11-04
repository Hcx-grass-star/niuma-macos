// swift-tools-version: 6.0
import PackageDescription

// 仅使用系统框架，便于离线构建并控制常驻体积。
// 最低 macOS 13：覆盖 Ventura 及之后的系统，同时保留 SMAppService 登录项能力。
let package = Package(
    name: "Niuma",
    platforms: [.macOS("13.0")],
    products: [.executable(name: "Niuma", targets: ["Niuma"])],
    targets: [
        .target(name: "NiumaCore"),
        .executableTarget(name: "Niuma", dependencies: ["NiumaCore"]),
        .executableTarget(name: "NiumaIntegrationTests", dependencies: ["NiumaCore"], path: "Tests/NiumaCoreTests")
    ]
)
