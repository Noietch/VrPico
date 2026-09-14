import Foundation

/// 设备端 shell 的转义工具。
///
/// 这里之所以需要它：`adb shell <cmd> [args...]` 会把参数用空格拼起来，
/// 交给**设备端的 sh -c** 执行。所以即使我们用 Process 的参数数组调 adb
/// （躲开了 Mac 本地的 shell），设备端仍然会再解释一遍。
///
/// Native EVA-VR WebSocket URLs are shell-quoted before being passed through
/// `adb shell`, for example:
///
///     ws://127.0.0.1:43876/ws?token=eva
///
/// 里面的 `&` 在设备端会被当成后台操作符，必须加引号。
public enum DeviceShell {

    /// 把字符串包成 POSIX 单引号形式。单引号内部除了 `'` 本身没有特殊字符，
    /// 因此这是最安全的包法；`'` 用标准的 `'\''` 序列转义。
    public static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
