import Foundation

/// 解析 `adb devices` / `adb devices -l` 的输出。
///
/// adb 在真正输出设备列表前可能先打印守护进程启动信息：
///
///     * daemon not running; starting now at tcp:5037
///     * daemon started successfully
///     List of devices attached
///     PA1234567890           device product:foo model:Pico_4_Ultra transport_id:1
///     PA0000000000           unauthorized
///
/// 因此必须先定位 `List of devices attached` 这一行，不能直接按行号切。
public enum AdbOutputParser {

    public static let header = "List of devices attached"

    public static func parseDevices(_ output: String) -> [AdbDevice] {
        var devices: [AdbDevice] = []
        var seenHeader = false

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if !seenHeader {
                if trimmed == header { seenHeader = true }
                continue
            }

            if trimmed.isEmpty { continue }
            // 守护进程日志等噪声行。
            if trimmed.hasPrefix("*") { continue }

            guard let device = parseDeviceLine(trimmed) else { continue }
            devices.append(device)
        }

        return devices
    }

    /// 单行格式：`<serial> <state> [key:value ...]`。
    static func parseDeviceLine(_ line: String) -> AdbDevice? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count >= 2 else { return nil }

        let serial = fields[0]
        let stateToken = fields[1]
        let remainder = Array(fields.dropFirst(2))

        // `no permissions (user in plugdev group; ...)` 的状态占两个词。
        let extra = remainder.joined(separator: " ")
        let state = AdbDeviceState(raw: stateToken, extra: extra)

        // 只有形如 key:value 的字段才是设备属性；
        // 紧随其后的自由文本（如 no permissions 的括号说明）忽略即可。
        var attributes: [String: String] = [:]
        for field in remainder {
            guard let colon = field.firstIndex(of: ":") else { continue }
            let key = String(field[field.startIndex..<colon])
            let value = String(field[field.index(after: colon)...])
            guard !key.isEmpty else { continue }
            attributes[key] = value
        }

        return AdbDevice(serial: serial, state: state, attributes: attributes)
    }

    /// 解析 `adb reverse --list` 的输出，取出已经建立的映射。
    ///
    /// 输出每行形如 `<serial> tcp:43876 tcp:43876`（部分版本不带 serial 前缀，
    /// 只有 `tcp:43876 tcp:43876`）。
    public static func parseReverseList(_ output: String) -> Set<String> {
        var mappings: Set<String> = []

        for line in output.split(separator: "\n") {
            let fields = line
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)

            // 取最后两个字段：<remote> <local>，形如 tcp:43876 tcp:43876。
            guard fields.count >= 2 else { continue }
            let remote = fields[fields.count - 2]
            let local = fields[fields.count - 1]
            guard remote.hasPrefix("tcp:"), local.hasPrefix("tcp:") else { continue }
            mappings.insert(remote)
        }

        return mappings
    }

    /// 某个端口是否已经存在 reverse 映射。用来判断映射是「本 App 建立」还是
    /// 「复用别人已有的」，后者退出时不能删除。
    public static func hasReverse(_ output: String, port: Int) -> Bool {
        parseReverseList(output).contains("tcp:\(port)")
    }
}
