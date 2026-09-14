// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VrPico",
    platforms: [.macOS(.v13)],
    targets: [
        // 纯逻辑：设置、ADB 解析、Relay、状态探测。不依赖 SwiftUI，便于单元测试。
        .target(name: "VrPicoCore"),

        // 状态栏 App。只负责 UI 与把 Core 串起来。
        .executableTarget(name: "VrPico", dependencies: ["VrPicoCore"]),

        .testTarget(name: "VrPicoCoreTests", dependencies: ["VrPicoCore"]),
    ]
)
