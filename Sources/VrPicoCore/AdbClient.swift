import Foundation

public enum AdbError: Error, LocalizedError {
    /// adb 命令返回非 0，附带原始输出供排查。
    case commandFailed(arguments: [String], result: ProcessResult)
    /// 需要一台设备，但当前没有可用设备。
    case noReadyDevice(AdbDeviceSummary)
    /// 有多台可用设备，调用方必须先让用户选一台。
    case ambiguousDevices([AdbDevice])

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let arguments, let result):
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = "adb " + arguments.joined(separator: " ")
            return detail.isEmpty
                ? "\(command) 失败（退出码 \(result.exitCode)）"
                : "\(command) 失败：\(detail)"

        case .noReadyDevice(let summary):
            switch summary {
            case .noDevices:
                return "没有检测到 Pico。请用 USB 连接头显。"
            case .unauthorized(let devices):
                let names = devices.map(\.serial).joined(separator: ", ")
                return "Pico 未授权（\(names)）。请在头显里确认「允许 USB 调试」。"
            case .offline(let devices):
                let names = devices.map(\.serial).joined(separator: ", ")
                return "Pico 处于离线状态（\(names)）。请重新插拔 USB 线。"
            default:
                return "Pico 当前不可用。"
            }

        case .ambiguousDevices(let devices):
            return "检测到 \(devices.count) 台可用设备，请选择要使用的一台。"
        }
    }
}

/// adb 的调用封装。
public struct AdbClient: Sendable {

    /// 使用独立端口，避免连接或控制系统、Homebrew、Android Studio 启动的 ADB server。
    public static let bundledServerPort: UInt16 = 5038

    public let executableURL: URL
    public let defaultTimeout: TimeInterval
    public let serverPort: UInt16

    public init(
        executableURL: URL,
        defaultTimeout: TimeInterval = 20,
        serverPort: UInt16 = Self.bundledServerPort
    ) {
        self.executableURL = executableURL
        self.defaultTimeout = defaultTimeout
        self.serverPort = serverPort
    }

    /// 从 App 内置位置构造。打包不完整或文件不可执行时返回 nil。
    public static func detected() -> AdbClient? {
        guard let location = AdbLocator.locate() else { return nil }
        return AdbClient(executableURL: location.url)
    }

    // MARK: - 底层

    @discardableResult
    public func run(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executableURL: executableURL,
            arguments: ["-P", String(serverPort)] + arguments,
            timeout: timeout ?? defaultTimeout
        )
    }

    /// 强校验版本：命令能跑通且返回 0 才算可用。
    public func isAvailable() async -> Bool {
        guard let result = try? await run(AdbCommand.version(), timeout: 10) else { return false }
        return result.succeeded
    }

    /// 只关闭内置 ADB 使用的独立 server，不触碰系统默认的 5037 端口。
    public func killServer() async throws {
        let arguments = AdbCommand.killServer()
        let result = try await run(arguments, timeout: 10)
        guard result.succeeded else {
            throw AdbError.commandFailed(arguments: arguments, result: result)
        }
    }

    // MARK: - 设备

    public func devices() async throws -> [AdbDevice] {
        // 第一次调用可能触发 adb 启动守护进程，给宽一点的超时。
        let result = try await run(AdbCommand.devicesList(), timeout: 30)
        guard result.succeeded else {
            throw AdbError.commandFailed(arguments: AdbCommand.devicesList(), result: result)
        }
        return AdbOutputParser.parseDevices(result.stdout)
    }

    /// 设备列表 + 归类，直接喂给 UI。
    public func deviceSummary() async throws -> AdbDeviceSummary {
        AdbDeviceSummary.summarize(try await devices())
    }

    // MARK: - Android packages

    /// Returns true when Android can resolve the native EVA package.
    ///
    /// `pm path` is intentionally used instead of parsing `dumpsys package`:
    /// it is small, stable across Android/PICO versions, and does not require
    /// knowing the installed version format.
    public func isPackageInstalled(
        serial: String,
        packageName: String = NativePicoApp.packageName
    ) async throws -> Bool {
        let arguments = AdbCommand.packagePath(serial: serial, packageName: packageName)
        let result = try await run(arguments)
        guard result.succeeded else {
            // Android's `pm path` returns exit code 1 when the package does not
            // exist. That is a normal "not installed" result, not an ADB
            // transport failure. Keep throwing for actual adb/device errors.
            let output = (result.stdout + "\n" + result.stderr).lowercased()
            let packageMissing = output.contains("unable to find package")
                || output.contains("package not found")
                || (result.exitCode == 1 && output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if packageMissing {
                return false
            }
            throw AdbError.commandFailed(arguments: arguments, result: result)
        }
        return result.stdout.split(whereSeparator: \.isNewline).contains {
            $0.hasPrefix("package:")
        }
    }

    /// Install the bundled native client. The caller must check first so a
    /// normal reconnect does not reinstall the APK.
    public func installAPK(serial: String, at apkURL: URL) async throws {
        let arguments = AdbCommand.installAPK(serial: serial, apkURL: apkURL)
        let result = try await run(arguments, timeout: 120)
        guard result.succeeded else {
            throw AdbError.commandFailed(arguments: arguments, result: result)
        }
    }

    // MARK: - reverse 映射

    public func reverseList(serial: String) async throws -> String {
        let arguments = AdbCommand.reverseList(serial: serial)
        let result = try await run(arguments)
        guard result.succeeded else {
            throw AdbError.commandFailed(arguments: arguments, result: result)
        }
        return result.stdout
    }

    /// Pico 是否已经有该端口的 reverse 映射。
    ///
    /// 用来区分「本 App 建立的映射」和「复用别人已有的映射」——
    /// 后者在退出时**不能**删除。
    public func hasReverse(serial: String, port: Int) async throws -> Bool {
        let output = try await reverseList(serial: serial)
        return AdbOutputParser.hasReverse(output, port: port)
    }

    public func addReverse(serial: String, port: Int) async throws {
        let arguments = AdbCommand.reverseAdd(serial: serial, port: port)
        let result = try await run(arguments)
        guard result.succeeded else {
            throw AdbError.commandFailed(arguments: arguments, result: result)
        }
    }

    public func removeReverse(serial: String, port: Int) async throws {
        let arguments = AdbCommand.reverseRemove(serial: serial, port: port)
        let result = try await run(arguments)
        guard result.succeeded else {
            throw AdbError.commandFailed(arguments: arguments, result: result)
        }
    }

    // MARK: - Native app

    /// Launch EVA-VR and pass the loopback WebSocket endpoint.
    public func openNativeApp(serial: String, serverURL: String) async throws {
        let arguments = AdbCommand.openNativeApp(serial: serial, serverURL: serverURL)
        let result = try await run(arguments)
        guard result.succeeded else {
            throw AdbError.commandFailed(arguments: arguments, result: result)
        }
    }

    /// Compatibility helper retained for the optional WebXR input mode.
    public func openURL(serial: String, url: String) async throws {
        let arguments = AdbCommand.openURL(serial: serial, url: url)
        let result = try await run(arguments)
        guard result.succeeded else {
            throw AdbError.commandFailed(arguments: arguments, result: result)
        }
    }
}

extension AdbDeviceSummary {
    /// 取出唯一可用设备的序列号；多台或没有可用设备时抛错。
    public func requireReadySerial() throws -> String {
        switch self {
        case .ready(let device):
            return device.serial
        case .multipleReady(let devices):
            throw AdbError.ambiguousDevices(devices)
        default:
            throw AdbError.noReadyDevice(self)
        }
    }

    public var readyDevices: [AdbDevice] {
        if case .multipleReady(let devices) = self { return devices }
        if case .ready(let device) = self { return [device] }
        return []
    }
}
