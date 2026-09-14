import XCTest
@testable import VrPicoCore

final class StatusProbeTests: XCTestCase {

    /// 设置界面允许端口暂时处于编辑中的非法值，探测必须返回错误而不是在
    /// Int -> UInt16 转换时触发 fatal error。
    func testProbeServerRejectsOutOfRangePortsWithoutCrashing() async {
        let settings = AppSettings(
            serverHost: "127.0.0.1",
            clientPort: -1,
            viserPort: 70_000,
            webxrPort: 70_000,
            webxrMode: "ar",
            picoSerial: ""
        )

        let result = await StatusProbe.probeServer(settings)

        XCTAssertEqual(result.client, .failed(reason: "地址无效"))
        XCTAssertEqual(result.viser, .failed(reason: "地址无效"))
        XCTAssertEqual(result.webxr, .failed(reason: "端口需要 1–65535"))
    }
}
