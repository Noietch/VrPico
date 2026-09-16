import XCTest
@testable import VrPicoCore

final class StatusProbeTests: XCTestCase {

    /// Invalid console/Viser ports must fail without crashing. The native
    /// input port is fixed and ignores the legacy persisted WebXR port.
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
        XCTAssertNotEqual(result.webxr, .failed(reason: "端口需要 1–65535"))
    }
}
