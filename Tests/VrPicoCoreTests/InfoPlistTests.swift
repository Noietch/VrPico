import XCTest
@testable import VrPicoCore

/// 守住打包用的 Info.plist。
///
/// 这些键出错的方式很隐蔽：单元测试跑在裸测试包里，看不到 .app 的 ATS 策略，
/// 所以 plist 的问题只会在真机上暴露。用测试钉住。
final class InfoPlistTests: XCTestCase {

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // VrPicoCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // 包根目录
    }

    private func loadInfoPlist() throws -> [String: Any] {
        let url = packageRoot.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any], "Info.plist 顶层应当是字典")
    }

    /// **这条是真踩过的坑。**
    ///
    /// EVA Console 和 WebXR 页面都是明文 HTTP。ATS 默认会以 -1022
    /// ("requires the use of a secure connection") 拦掉所有探测，
    /// 表现为界面显示"连接失败"但服务器其实完全正常。
    ///
    /// 而且这个问题在裸二进制冒烟测试里看不出来——只有装进 .app 才触发。
    func testATSAllowsPlainHTTP() throws {
        let plist = try loadInfoPlist()
        let ats = try XCTUnwrap(
            plist["NSAppTransportSecurity"] as? [String: Any],
            "缺少 NSAppTransportSecurity，明文 HTTP 会被 ATS 拦掉"
        )
        XCTAssertEqual(
            ats["NSAllowsArbitraryLoads"] as? Bool,
            true,
            "NSAllowsArbitraryLoads 必须为 true：服务器地址是用户可配的任意 IP，可能不在私有网段，NSAllowsLocalNetworking 覆盖不到"
        )
    }

    /// 纯状态栏 App：不能在 Dock 里出现图标。
    func testRunsAsMenuBarOnlyApp() throws {
        let plist = try loadInfoPlist()

        XCTAssertEqual(plist["LSUIElement"] as? Bool, true, "LSUIElement 必须为 true")
    }

    /// 可执行文件名必须和 build_app.sh 拷进 MacOS/ 的文件一致，否则 App 起不来。
    func testBundleExecutableMatchesBuildScript() throws {
        let plist = try loadInfoPlist()

        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "VrPico")

        let scriptURL = packageRoot.appendingPathComponent("scripts/build_app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("APP_NAME=\"VrPico\""), "打包脚本里的 APP_NAME 应当与 CFBundleExecutable 一致")
    }

    func testMinimumSystemVersionIsSet() throws {
        let plist = try loadInfoPlist()

        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "13.0")
    }

    /// ADB 已随 App 分发，不应再请求控制 Terminal 的自动化权限。
    func testDoesNotRequestTerminalAutomationPermission() throws {
        let plist = try loadInfoPlist()
        XCTAssertNil(plist["NSAppleEventsUsageDescription"])
    }
}
