import Foundation

/// 找到 App 自带的 adb。
///
/// VrPico 不读取系统 PATH、Homebrew 或 Android SDK，也不接受用户指定路径。
/// 这样所有机器始终使用随 App 验证和发布的同一个版本。
public struct AdbLocation: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case bundled
    }

    public let url: URL
    public let source: Source

    public init(url: URL, source: Source) {
        self.url = url
        self.source = source
    }

    /// 设置界面展示用。
    public var sourceDescription: String {
        "App 内置"
    }
}

public enum AdbLocator {

    public static let relativePath = "Contents/Helpers/adb"

    public static func bundledURL(bundleURL: URL = Bundle.main.bundleURL) -> URL {
        bundleURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    /// 只接受 App bundle 内的固定路径。`bundleURL` 和 `isExecutable` 可注入，
    /// 便于单元测试不依赖正在运行的测试包结构。
    public static func locate(
        bundleURL: URL = Bundle.main.bundleURL,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> AdbLocation? {
        let url = bundledURL(bundleURL: bundleURL)
        guard isExecutable(url.path) else { return nil }
        return AdbLocation(url: url, source: .bundled)
    }
}
