import XCTest
@testable import VrPicoCore

final class DeviceShellTests: XCTestCase {

    func testSingleQuoteWrapsPlainValue() {
        XCTAssertEqual(DeviceShell.singleQuote("abc"), "'abc'")
    }

    /// 单引号内的 `&` 不会被设备端 sh 当成后台操作符，这正是我们要的。
    func testSingleQuoteProtectsAmpersand() {
        let quoted = DeviceShell.singleQuote("http://127.0.0.1:43876/?token=a&mode=ar")

        XCTAssertEqual(quoted, "'http://127.0.0.1:43876/?token=a&mode=ar'")
    }

    /// 值里本身有单引号时必须转义，否则会提前闭合引号。
    func testSingleQuoteEscapesEmbeddedQuote() {
        let quoted = DeviceShell.singleQuote("it's")

        XCTAssertEqual(quoted, "'it'\\''s'")
    }
}

final class AdbCommandTests: XCTestCase {

    func testKillServer() {
        XCTAssertEqual(AdbCommand.killServer(), ["kill-server"])
    }

    func testReverseAddUsesSamePortOnBothSides() {
        XCTAssertEqual(
            AdbCommand.reverseAdd(serial: "PA1", port: 43876),
            ["-s", "PA1", "reverse", "tcp:43876", "tcp:43876"]
        )
    }

    func testReverseRemove() {
        XCTAssertEqual(
            AdbCommand.reverseRemove(serial: "PA1", port: 43876),
            ["-s", "PA1", "reverse", "--remove", "tcp:43876"]
        )
    }

    /// 整条 am start 必须是**一个**参数：adb 会把参数拼起来交给设备端 sh，
    /// 拆成多个参数同样能跑，但合起来才能保证引号原样送达。
    func testOpenURLPassesRemoteCommandAsSingleArgument() {
        let url = "http://127.0.0.1:43876/?token=t&mode=ar&reload=1"
        let arguments = AdbCommand.openURL(serial: "PA1", url: url)

        XCTAssertEqual(arguments.count, 4)
        XCTAssertEqual(Array(arguments.prefix(3)), ["-s", "PA1", "shell"])
        XCTAssertEqual(
            arguments[3],
            "am start -S -a android.intent.action.VIEW -d 'http://127.0.0.1:43876/?token=t&mode=ar&reload=1'"
        )
    }

    /// token 里混进单引号时不能逃逸出引号。
    func testOpenURLEscapesQuoteInToken() {
        let url = "http://127.0.0.1:43876/?token=a'b&mode=ar"
        let arguments = AdbCommand.openURL(serial: "PA1", url: url)

        XCTAssertTrue(arguments[3].hasSuffix("-d 'http://127.0.0.1:43876/?token=a'\\''b&mode=ar'"))
    }

    func testDevicesListUsesLongFormat() {
        XCTAssertEqual(AdbCommand.devicesList(), ["devices", "-l"])
    }

    func testPackagePathUsesTheSelectedDevice() {
        XCTAssertEqual(
            AdbCommand.packagePath(serial: "PA1", packageName: NativePicoApp.packageName),
            ["-s", "PA1", "shell", "pm", "path", "org.eva.pico.input"]
        )
    }

    func testInstallAPKUsesTheSelectedDeviceAndPreservesPath() {
        let apk = URL(fileURLWithPath: "/tmp/EVA-PICO.apk")

        XCTAssertEqual(
            AdbCommand.installAPK(serial: "PA1", apkURL: apk),
            ["-s", "PA1", "install", "-r", "/tmp/EVA-PICO.apk"]
        )
    }
}

final class AdbLocatorTests: XCTestCase {

    func testLocatesOnlyBundledAdb() {
        let bundleURL = URL(fileURLWithPath: "/Applications/VrPico.app")
        let expected = "/Applications/VrPico.app/Contents/Helpers/adb"
        var inspectedPaths: [String] = []

        let location = AdbLocator.locate(bundleURL: bundleURL) { path in
            inspectedPaths.append(path)
            return path == expected
        }

        XCTAssertEqual(inspectedPaths, [expected])
        XCTAssertEqual(location?.url.path, expected)
        XCTAssertEqual(location?.source, .bundled)
        XCTAssertEqual(location?.sourceDescription, "App 内置")
    }

    func testMissingBundledAdbDoesNotFallBackToSystem() {
        let bundleURL = URL(fileURLWithPath: "/Applications/VrPico.app")

        let location = AdbLocator.locate(bundleURL: bundleURL) { _ in false }

        XCTAssertNil(location)
    }
}
