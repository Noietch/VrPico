import XCTest
@testable import VrPicoCore

final class AppSettingsTests: XCTestCase {

    private func settings(
        host: String = "10.0.0.1",
        client: Int = 8415,
        viser: Int = 8416,
        webxr: Int = 8417
    ) -> AppSettings {
        AppSettings(
            serverHost: host,
            clientPort: client,
            viserPort: viser,
            webxrPort: webxr,
            webxrMode: "ar",
            picoSerial: ""
        )
    }

    // MARK: - 默认值

    /// 默认端口是团队约定值，对应远端的启动参数，**不是**远端代码的默认值
    /// （远端代码分别是 8080 / 8092 / 8443）。两列数字不一样是正常的。
    func testDefaultsMatchTeamConvention() {
        XCTAssertEqual(AppSettings.defaultClientPort, 8415)
        XCTAssertEqual(AppSettings.defaultViserPort, 8416)
        XCTAssertEqual(AppSettings.defaultWebXRPort, 8417)
        XCTAssertEqual(AppSettings.default.clientPort, 8415)
        XCTAssertEqual(AppSettings.default.viserPort, 8416)
        XCTAssertEqual(AppSettings.default.webxrPort, 8417)
        XCTAssertEqual(AppSettings.default.webxrMode, "ar")
    }

    /// 端口必须能改，且改动要一路传到 Pico 的 URL 上。
    /// 用一组和默认值都不同的端口，防止哪里写死了默认值。
    func testCustomPortsAreHonoured() {
        let custom = settings(client: 9001, viser: 9002, webxr: 9003)

        XCTAssertEqual(custom.clientURL?.absoluteString, "http://10.0.0.1:9001/")
        XCTAssertEqual(custom.viserURL?.absoluteString, "http://10.0.0.1:9002/")
        XCTAssertTrue(custom.picoURL(token: "t", reload: 1).hasPrefix("http://127.0.0.1:9003/?"))
    }

    func testDefaultIsInvalidUntilHostIsFilledIn() {
        let issues = AppSettings.default.validate()

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.field, .serverHost)
    }

    // MARK: - 校验

    func testValidSettingsProduceNoIssues() {
        XCTAssertTrue(settings().validate().isEmpty)
    }

    func testWhitespaceOnlyHostIsRejected() {
        let issues = settings(host: "   ").validate()

        XCTAssertEqual(issues.first?.field, .serverHost)
    }

    func testHostWithSpaceIsRejected() {
        let issues = settings(host: "10.0.0.1 10.0.0.2").validate()

        XCTAssertEqual(issues.first?.field, .serverHost)
    }

    func testHostCannotContainSchemePortOrPathSyntax() {
        for host in ["http://10.0.0.1", "example.com/path", "example.com?x=1", "[::1]", "example.com:8417"] {
            XCTAssertEqual(settings(host: host).validate().first?.field, .serverHost, "实际: \(host)")
            XCTAssertNil(settings(host: host).clientURL)
        }
    }

    func testHostWithNonSpaceWhitespaceIsRejected() {
        XCTAssertEqual(settings(host: "foo\tbar").validate().first?.field, .serverHost)
    }

    func testPortOutOfRangeIsRejected() {
        XCTAssertEqual(settings(client: 0).validate().first?.field, .clientPort)
        XCTAssertEqual(settings(viser: 70000).validate().first?.field, .viserPort)
        XCTAssertEqual(settings(webxr: -1).validate().first?.field, .webxrPort)
    }

    func testOutOfRangePortsDoNotProduceURLs() {
        XCTAssertNil(settings(client: 70000).clientURL)
        XCTAssertNil(settings(viser: -1).viserURL)
    }

    /// 多个字段同时出错时要一次报全，界面才能一起标红。
    func testAllIssuesReportedAtOnce() {
        let issues = settings(host: "", client: 0, viser: 0, webxr: 0).validate()

        XCTAssertEqual(Set(issues.map(\.field)), [.serverHost, .clientPort, .viserPort, .webxrPort])
    }

    // MARK: - URL

    func testClientAndViserURLsUseServerHost() {
        XCTAssertEqual(settings().clientURL?.absoluteString, "http://10.0.0.1:8415/")
        XCTAssertEqual(settings().viserURL?.absoluteString, "http://10.0.0.1:8416/")
    }

    func testHostIsTrimmedInURLs() {
        XCTAssertEqual(settings(host: "  10.0.0.1\n").clientURL?.absoluteString, "http://10.0.0.1:8415/")
    }

    /// IPv6 字面量不加方括号拼不出合法 URL。
    func testIPv6HostIsBracketed() {
        XCTAssertEqual(settings(host: "fe80::1").clientURL?.absoluteString, "http://[fe80::1]:8415/")
    }

    func testScopedIPv6HostEncodesZoneSeparator() {
        XCTAssertEqual(
            settings(host: "fe80::1%en0").clientURL?.absoluteString,
            "http://[fe80::1%25en0]:8415/"
        )
    }

    /// Pico 侧必须是 localhost：WebXR 要求 secure context，
    /// 走远端 IP 就得配 HTTPS 证书。
    func testPicoURLAlwaysTargetsLoopback() {
        let url = settings(host: "10.0.0.1", webxr: 43876).picoURL(token: "tok", reload: 123)

        XCTAssertTrue(url.hasPrefix("http://127.0.0.1:43876/?"))
        XCTAssertFalse(url.contains("10.0.0.1"))
    }

    func testPicoURLCarriesTokenModeAndReload() {
        let url = settings(webxr: 9000).picoURL(token: "eva-pico4-ultra-vr", reload: 1700000000)

        XCTAssertTrue(url.contains("token=eva-pico4-ultra-vr"))
        XCTAssertTrue(url.contains("mode=ar"))
        XCTAssertTrue(url.contains("reload=1700000000"))
    }

    /// token 里的 URL 保留字符必须编码，否则 `&` 会截断查询串。
    func testPicoURLPercentEncodesToken() {
        let url = settings().picoURL(token: "a&b=c", reload: 1)

        XCTAssertTrue(url.contains("token=a%26b%3Dc"), "实际: \(url)")
        XCTAssertFalse(url.contains("token=a&b=c"))
    }
}

final class AppSettingsStoreTests: XCTestCase {

    private func makeStore() -> (AppSettingsStore, UserDefaults, String) {
        let suiteName = "AppSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (AppSettingsStore(defaults: defaults), defaults, suiteName)
    }

    func testTokenIsStoredAsOrdinaryUserDefaultString() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        store.saveToken("plain-token")

        XCTAssertEqual(defaults.string(forKey: AppSettingsStore.webXRTokenKey), "plain-token")
        XCTAssertEqual(store.loadToken(), "plain-token")
    }

    func testDefaultTokenIsUsedOnlyBeforeAValueHasBeenSaved() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(store.loadTokenOrDefault(), AppSettings.defaultWebXRToken)

        store.saveToken("")
        XCTAssertEqual(store.loadTokenOrDefault(), "")
    }

    func testResetRemovesStoredToken() {
        let (store, defaults, suiteName) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.saveToken("plain-token")

        store.reset()

        XCTAssertNil(defaults.object(forKey: AppSettingsStore.webXRTokenKey))
    }
}
