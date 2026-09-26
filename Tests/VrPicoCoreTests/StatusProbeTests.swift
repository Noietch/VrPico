import Network
import XCTest
@testable import VrPicoCore

final class StatusProbeTests: XCTestCase {

    /// Invalid console/Viser ports must fail without crashing. The native port
    /// is configurable now, so an unusable value is reported rather than being
    /// silently coerced to a fixed default.
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
        XCTAssertEqual(result.webxr, .failed(reason: "端口无效"))
    }

    /// A closed port must report unreachable rather than hang.
    func testWebSocketReachableIsFalseWhenNothingListens() async {
        let url = URL(string: "ws://127.0.0.1:1/ws")!

        let reachable = await StatusProbe.webSocketReachable(url: url, timeout: 2)

        XCTAssertFalse(reachable)
    }

    /// A real node answers an unauthenticated handshake with 401. Treating that
    /// as "reachable" is what lets VrPico recognise a user's own SSH tunnel
    /// instead of trying to bind the port itself.
    func testAuthChallengeCountsAsReachableWhenRequested() async throws {
        let server = try LoopbackStatusServer(status: 401)
        defer { server.stop() }

        let url = URL(string: "ws://127.0.0.1:\(server.port)/ws")!

        let lenient = await StatusProbe.webSocketReachable(
            url: url, timeout: 3, acceptAuthChallenge: true
        )
        let strict = await StatusProbe.webSocketReachable(url: url, timeout: 3)

        XCTAssertTrue(lenient)
        XCTAssertFalse(strict)
    }

    /// A 200 answer means "something is there but not at this path"; it still
    /// counts as reachable when no auth challenge is expected.
    func testSuccessStatusIsReachable() async throws {
        let server = try LoopbackStatusServer(status: 200)
        defer { server.stop() }

        let url = URL(string: "ws://127.0.0.1:\(server.port)/ws")!

        let reachable = await StatusProbe.webSocketReachable(url: url, timeout: 3)

        XCTAssertTrue(reachable)
    }
}

/// 最小回环 HTTP 服务：读掉请求后回一个固定状态码。
///
/// 只用于验证握手探测的判定分支，因此不解析请求内容。
private final class LoopbackStatusServer {
    let port: UInt16
    private let listener: NWListener

    init(status: Int) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let response = "HTTP/1.1 \(status) Status\r\n"
                    + "Content-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(response.utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success,
              let assigned = listener.port else {
            throw XCTSkip("无法启动回环测试服务")
        }
        port = assigned.rawValue
    }

    func stop() {
        listener.cancel()
    }
}
