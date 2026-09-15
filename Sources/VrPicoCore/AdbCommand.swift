import Foundation

/// adb 命令的参数构造。
///
/// 单独抽出来是为了能直接对「生成了什么命令」写断言——尤其是打开 Pico 那条，
/// 设备端 shell 的转义错了会静默失败，很难排查。
public enum AdbCommand {

    public static func version() -> [String] {
        ["version"]
    }

    public static func killServer() -> [String] {
        ["kill-server"]
    }

    public static func devicesList() -> [String] {
        ["devices", "-l"]
    }

    /// Query whether an Android package is installed on one device.
    public static func packagePath(serial: String, packageName: String) -> [String] {
        ["-s", serial, "shell", "pm", "path", packageName]
    }

    /// Install an APK from the Mac without involving a shell.
    public static func installAPK(serial: String, apkURL: URL) -> [String] {
        ["-s", serial, "install", "-r", apkURL.path]
    }

    public static func getState(serial: String) -> [String] {
        ["-s", serial, "get-state"]
    }

    public static func reverseList(serial: String) -> [String] {
        ["-s", serial, "reverse", "--list"]
    }

    public static func reverseAdd(serial: String, port: Int) -> [String] {
        ["-s", serial, "reverse", "tcp:\(port)", "tcp:\(port)"]
    }

    public static func reverseRemove(serial: String, port: Int) -> [String] {
        ["-s", serial, "reverse", "--remove", "tcp:\(port)"]
    }

    /// Launch the native EVA-VR APK with its WebSocket endpoint.
    public static func openNativeApp(
        serial: String,
        packageName: String = "org.eva.pico.input",
        serverURL: String
    ) -> [String] {
        let remoteCommand = "am force-stop \(packageName); am start -S -n \(packageName)/.MainActivity --es server_url \(DeviceShell.singleQuote(serverURL))"
        return ["-s", serial, "shell", remoteCommand]
    }

    /// Compatibility helper retained for the optional WebXR input mode.
    public static func openURL(serial: String, url: String) -> [String] {
        let remoteCommand = "am start -S -a android.intent.action.VIEW -d \(DeviceShell.singleQuote(url))"
        return ["-s", serial, "shell", remoteCommand]
    }
}
