import AppKit
import SwiftUI

@main
struct VrPicoApp: App {

    // 让 AppDelegate 持有 controller：它在 App 启动时就存在，
    // 退出钩子才能可靠地拿到它做清理。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("EVA-VR Relay", systemImage: "link.circle.fill") {
            MainView(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)

        // 设置窗口不走 SwiftUI 场景，见 SettingsWindowController 里的说明。
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let controller = AppController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.debug("didFinishLaunching argv=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
        controller.start()

        // 菜单栏图标被系统挤掉、或藏在刘海后面时，可以直接从命令行开设置：
        //   VrPico.app/Contents/MacOS/VrPico --open-settings
        // 推迟一个 runloop：didFinishLaunching 期间应用还没完成激活流程，
        // 此时建出来的窗口不会上屏。
        if CommandLine.arguments.contains("--open-settings") {
            DispatchQueue.main.async {
                SettingsWindowController.shared.show(controller: self.controller)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 清理自己的 Relay、ADB reverse 和独立端口上的内置 ADB server。
        // 强制退出（Force Quit）不会走到这里，所以 cleanup 是尽力而为。
        controller.cleanupBeforeQuit()
    }
}
