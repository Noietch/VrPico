import XCTest
@testable import VrPicoCore

final class AdbOutputParserTests: XCTestCase {

    func testParsesSingleReadyDeviceWithAttributes() {
        let output = """
        List of devices attached
        PA1234567890           device product:PICO4Ultra model:PICO_4_Ultra device:PICO transport_id:1

        """

        let devices = AdbOutputParser.parseDevices(output)

        XCTAssertEqual(devices.count, 1)
        let device = try? XCTUnwrap(devices.first)
        XCTAssertEqual(device?.serial, "PA1234567890")
        XCTAssertEqual(device?.state, .device)
        XCTAssertEqual(device?.model, "PICO_4_Ultra")
        XCTAssertEqual(device?.attributes["transport_id"], "1")
    }

    /// adb 首次启动时会先打印守护进程日志，不能按行号切。
    func testIgnoresDaemonPreamble() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        PA1234567890\tdevice

        """

        let devices = AdbOutputParser.parseDevices(output)

        XCTAssertEqual(devices.map(\.serial), ["PA1234567890"])
    }

    func testEmptyDeviceList() {
        let output = """
        List of devices attached

        """

        XCTAssertTrue(AdbOutputParser.parseDevices(output).isEmpty)
        XCTAssertEqual(AdbDeviceSummary.summarize([]), .noDevices)
    }

    func testUnauthorizedIsReportedNotIgnored() {
        let output = """
        List of devices attached
        PA1234567890           unauthorized

        """

        let devices = AdbOutputParser.parseDevices(output)

        XCTAssertEqual(devices.first?.state, .unauthorized)
        XCTAssertEqual(AdbDeviceSummary.summarize(devices), .unauthorized(devices))
    }

    func testOfflineIsReported() {
        let output = """
        List of devices attached
        PA1234567890           offline

        """

        let devices = AdbOutputParser.parseDevices(output)

        XCTAssertEqual(AdbDeviceSummary.summarize(devices), .offline(devices))
    }

    /// 未授权比离线更值得优先提示，因为用户能立刻去头显里点确认。
    func testUnauthorizedWinsOverOffline() {
        let output = """
        List of devices attached
        PA111                    offline
        PA222                    unauthorized

        """

        let devices = AdbOutputParser.parseDevices(output)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(AdbDeviceSummary.summarize(devices), .unauthorized([devices[1]]))
    }

    func testSingleReadyDeviceSummarizesAsReady() {
        let output = """
        List of devices attached
        PA1234567890           device

        """

        let devices = AdbOutputParser.parseDevices(output)

        XCTAssertEqual(AdbDeviceSummary.summarize(devices), .ready(devices[0]))
    }

    /// 多台时必须让用户选，不能静默取第一台。
    func testMultipleReadyDevicesAreNotSilentlyPicked() {
        let output = """
        List of devices attached
        PA111                  device
        PA222                  device

        """

        let devices = AdbOutputParser.parseDevices(output)

        XCTAssertEqual(AdbDeviceSummary.summarize(devices), .multipleReady(devices))
    }

    /// `no permissions (user in plugdev group; ...)` 的状态字段占两个词。
    func testNoPermissionsWithSpacesInState() {
        let output = """
        List of devices attached
        PA1234567890\tno permissions (user in plugdev group; are your udev rules wrong?)

        """

        let devices = AdbOutputParser.parseDevices(output)

        XCTAssertEqual(devices.first?.state, .noPermissions)
        XCTAssertEqual(AdbDeviceSummary.summarize(devices), .unauthorized(devices))
    }

    /// adb 未来新增状态时不能崩，也不能丢。
    func testUnknownStateIsPreserved() {
        let output = """
        List of devices attached
        PA1234567890           brand_new_state

        """

        let devices = AdbOutputParser.parseDevices(output)

        XCTAssertEqual(devices.first?.state, .unknown("brand_new_state"))
        XCTAssertEqual(AdbDeviceSummary.summarize(devices), .other(devices))
    }

    func testDeviceDisplayNamePrefersModel() {
        let device = AdbDevice(serial: "PA111", state: .device, attributes: ["model": "PICO_4_Ultra"])

        XCTAssertEqual(device.displayName, "PICO_4_Ultra (PA111)")
        XCTAssertEqual(AdbDevice(serial: "PA111", state: .device).displayName, "PA111")
    }

    // MARK: - adb reverse --list

    func testReverseListWithSerialPrefix() {
        let output = """
        PA1234567890 tcp:43876 tcp:43876
        PA1234567890 tcp:8081 tcp:8081

        """

        XCTAssertEqual(
            AdbOutputParser.parseReverseList(output),
            ["tcp:43876", "tcp:8081"]
        )
    }

    /// 部分 adb 版本的 --list 不带 serial 前缀。
    func testReverseListWithoutSerialPrefix() {
        let output = "tcp:43876 tcp:43876\n"

        XCTAssertTrue(AdbOutputParser.hasReverse(output, port: 43876))
        XCTAssertFalse(AdbOutputParser.hasReverse(output, port: 8415))
    }

    func testReverseListEmpty() {
        XCTAssertTrue(AdbOutputParser.parseReverseList("").isEmpty)
        XCTAssertFalse(AdbOutputParser.hasReverse("", port: 43876))
    }
}
