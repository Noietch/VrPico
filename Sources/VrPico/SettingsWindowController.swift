import AppKit
import SwiftUI

/// 设置窗口。
///
/// 用 `NSWindow` 手工管理，而不是 SwiftUI 的 `Settings` 场景。
///
/// 原因是踩过的坑：状态栏 App（LSUIElement）从来没有 key window，而
/// `Settings` 场景要靠 `showSettingsWindow:` / `showPreferencesWindow:`
/// 这类私有 selector 打开，那条路依赖响应者链，找不到接收者就会**静默失败**——
/// 表现就是「点设置没反应」，不报错也没有日志。
///
/// 手工管理还顺带解决了另外两件事：可以从任意位置调用（菜单栏按钮、
/// AppDelegate、命令行参数），以及关掉之后还能再打开。
@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func show(controller: AppController) {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(controller: controller))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "VR Pico 设置"
            window.contentView = hosting
            window.center()
            // 关掉后系统不要释放，否则第二次打开要重建，位置也会重置。
            window.isReleasedWhenClosed = false
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // 状态栏 App 是 .accessory 策略，未必能成为活跃应用；这一句无视
        // 激活状态把窗口提到最前，否则窗口会开在别的应用后面，
        // 看起来还是像「没反应」。
        window?.orderFrontRegardless()

        // 从 Finder 启动时 stderr 无处可去，这几行不影响正常使用；
        // 从终端启动排查问题时很有用。
        Log.debug("设置窗口 visible=\(window?.isVisible ?? false) frame=\(String(describing: window?.frame))")
    }

    func close() {
        window?.close()
    }
}
