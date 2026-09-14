import Foundation

/// `adb devices -l` 里单个设备的状态。
///
/// 未知状态保留原始字符串，避免 adb 升级引入新状态时被静默丢弃。
public enum AdbDeviceState: Equatable, Sendable {
    case device
    case unauthorized
    case offline
    /// udev 权限问题，macOS 上少见但 adb 会输出。
    case noPermissions
    case bootloader
    case recovery
    case sideload
    case authorizing
    case connecting
    case unknown(String)

    /// 从 adb 输出的状态字段构造。`extra` 是状态之后的原始文本，用于识别
    /// `no permissions (user in plugdev group; ...)` 这种带空格的多词状态。
    public init(raw: String, extra: String = "") {
        switch raw {
        case "device": self = .device
        case "unauthorized": self = .unauthorized
        case "offline": self = .offline
        case "no": self = extra.hasPrefix("permissions") ? .noPermissions : .unknown("no \(extra)".trimmingCharacters(in: .whitespaces))
        case "bootloader": self = .bootloader
        case "recovery": self = .recovery
        case "sideload": self = .sideload
        case "authorizing": self = .authorizing
        case "connecting": self = .connecting
        default: self = .unknown(raw)
        }
    }

    public var isReady: Bool { self == .device }

    /// 用于设置界面「检测 Pico」按钮的展示文案。
    public var displayName: String {
        switch self {
        case .device: return "已连接"
        case .unauthorized: return "未授权"
        case .offline: return "离线"
        case .noPermissions: return "权限不足"
        case .bootloader: return "bootloader"
        case .recovery: return "recovery"
        case .sideload: return "sideload"
        case .authorizing: return "授权中"
        case .connecting: return "连接中"
        case .unknown(let raw): return raw
        }
    }
}

public struct AdbDevice: Equatable, Sendable, Identifiable {
    public let serial: String
    public let state: AdbDeviceState
    /// `-l` 输出里的 `key:value` 字段，例如 model / product / device / transport_id。
    public let attributes: [String: String]

    public var id: String { serial }

    public init(serial: String, state: AdbDeviceState, attributes: [String: String] = [:]) {
        self.serial = serial
        self.state = state
        self.attributes = attributes
    }

    public var model: String? { attributes["model"] }
    public var product: String? { attributes["product"] }

    /// 弹设备选择框时展示，优先显示机型而不是裸序列号。
    public var displayName: String {
        if let model, !model.isEmpty {
            return "\(model) (\(serial))"
        }
        return serial
    }
}

/// 对一批设备做「能不能直接用」的判定，供 UI 直接展示。
public enum AdbDeviceSummary: Equatable, Sendable {
    /// 一个授权且可用的设备，可以直接用。
    case ready(AdbDevice)
    /// 多台可用设备。**不要静默选第一台**，必须让用户选。
    case multipleReady([AdbDevice])
    /// 设备插着但没在头显里确认 USB 调试。
    case unauthorized([AdbDevice])
    /// 设备掉线，通常需要重新插拔 USB。
    case offline([AdbDevice])
    /// 插着但状态无法识别。
    case other([AdbDevice])
    /// 没有检测到任何设备。
    case noDevices

    public static func summarize(_ devices: [AdbDevice]) -> AdbDeviceSummary {
        let ready = devices.filter { $0.state.isReady }
        if ready.count == 1 { return .ready(ready[0]) }
        if ready.count > 1 { return .multipleReady(ready) }

        // 没有可用设备时，优先报告最需要用户动手的状态。
        let blocked = devices.filter { $0.state == .unauthorized || $0.state == .noPermissions }
        if !blocked.isEmpty { return .unauthorized(blocked) }

        let offline = devices.filter { $0.state == .offline }
        if !offline.isEmpty { return .offline(offline) }

        if devices.isEmpty { return .noDevices }
        return .other(devices)
    }
}
