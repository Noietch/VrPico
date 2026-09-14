import Network
import XCTest
@testable import VrPicoCore

/// Relay 是整条链路里最关键的一环，这里覆盖它的真实行为：
/// 双向转发、大流量分块、并发连接、只监听回环、端口冲突、停止后释放。
final class TcpRelayTests: XCTestCase {

    // 每个用例用不同端口，避免相互干扰。
    private enum Port {
        static let smallRoundTrip: UInt16 = 38601
        static let largePayload: UInt16 = 38602
        static let concurrent: UInt16 = 38603
        static let stats: UInt16 = 38604
        static let portInUse: UInt16 = 38605
        static let restart: UInt16 = 38606
        static let loopbackOnly: UInt16 = 38607
    }

    private var echo: EchoServer!
    private var relay: TcpRelay!

    override func setUp() async throws {
        try await super.setUp()
        echo = try EchoServer()
    }

    override func tearDown() async throws {
        relay?.stop()
        relay = nil
        echo?.stop()
        echo = nil
        try await super.tearDown()
    }

    private func makeRelay(port: UInt16) async throws -> TcpRelay {
        let relay = TcpRelay(listenPort: port, upstreamHost: "127.0.0.1", upstreamPort: echo.port)
        try await relay.start()
        self.relay = relay
        return relay
    }

    // MARK: - 转发

    func testSmallRoundTrip() async throws {
        _ = try await makeRelay(port: Port.smallRoundTrip)

        let received = SocketClient.roundTrip(host: "127.0.0.1", port: Port.smallRoundTrip, bytes: 13)

        XCTAssertEqual(received, 13)
    }

    /// 超过单次 receive 上限的流量必须完整送达，验证分块与背压。
    func testLargePayloadIsForwardedCompletely() async throws {
        _ = try await makeRelay(port: Port.largePayload)

        let size = 1 << 20
        let received = SocketClient.roundTrip(host: "127.0.0.1", port: Port.largePayload, bytes: size, timeout: 30)

        XCTAssertEqual(received, size)
    }

    /// WebXR 页面加载和 WebSocket 是不同连接，必须能并发。
    func testConcurrentConnections() async throws {
        _ = try await makeRelay(port: Port.concurrent)

        let results = await withCheckedContinuation { (continuation: CheckedContinuation<[Int?], Never>) in
            DispatchQueue.global().async {
                let lock = NSLock()
                var results = [Int?](repeating: nil, count: 8)
                DispatchQueue.concurrentPerform(iterations: 8) { index in
                    let expected = 1024 * (index + 1)
                    let got = SocketClient.roundTrip(
                        host: "127.0.0.1",
                        port: Port.concurrent,
                        bytes: expected,
                        timeout: 30
                    )
                    lock.lock()
                    results[index] = got
                    lock.unlock()
                }
                continuation.resume(returning: results)
            }
        }

        for (index, got) in results.enumerated() {
            XCTAssertEqual(got, 1024 * (index + 1), "第 \(index) 条连接的字节数不对")
        }
    }

    // MARK: - 统计

    func testStatsTrackTrafficAndConnections() async throws {
        let relay = try await makeRelay(port: Port.stats)

        XCTAssertTrue(relay.currentStats.isRunning)
        XCTAssertEqual(relay.currentStats.activeConnections, 0)
        XCTAssertFalse(relay.currentStats.hasTraffic)

        _ = SocketClient.roundTrip(host: "127.0.0.1", port: Port.stats, bytes: 4096)

        let stats = relay.currentStats
        XCTAssertEqual(stats.totalConnections, 1)
        XCTAssertEqual(stats.bytesToUpstream, 4096)
        XCTAssertEqual(stats.bytesToClient, 4096)
        XCTAssertTrue(stats.hasTraffic)
        XCTAssertNotNil(stats.lastActivityAt)
    }

    // MARK: - 安全

    /// 绝不能监听 0.0.0.0，否则同网段的人都能借道访问内网服务器。
    func testListensOnLoopbackOnly() async throws {
        _ = try await makeRelay(port: Port.loopbackOnly)

        XCTAssertTrue(
            SocketClient.isReachable(host: "127.0.0.1", port: Port.loopbackOnly),
            "回环地址应当连得上"
        )

        if let lan = SocketClient.nonLoopbackIPv4() {
            XCTAssertFalse(
                SocketClient.isReachable(host: lan, port: Port.loopbackOnly),
                "从局域网地址 \(lan) 不应连得上"
            )
        }
    }

    // MARK: - 生命周期

    func testPortInUseIsReportedClearly() async throws {
        _ = try await makeRelay(port: Port.portInUse)

        let clash = TcpRelay(listenPort: Port.portInUse, upstreamHost: "127.0.0.1", upstreamPort: echo.port)
        defer { clash.stop() }

        do {
            try await clash.start()
            XCTFail("重复绑定同一端口应当失败")
        } catch let error as RelayError {
            XCTAssertEqual(error, .portInUse(Port.portInUse))
        }
    }

    /// 停止后端口要能立刻重新绑定——否则 App 重启会遇到「端口被占用」。
    func testStopReleasesPort() async throws {
        let relay = try await makeRelay(port: Port.restart)
        relay.stop()

        XCTAssertFalse(relay.currentStats.isRunning)
        XCTAssertEqual(relay.currentStats.activeConnections, 0)

        let restarted = TcpRelay(listenPort: Port.restart, upstreamHost: "127.0.0.1", upstreamPort: echo.port)
        defer { restarted.stop() }
        try await restarted.start()
        XCTAssertTrue(restarted.currentStats.isRunning)
    }
}

// MARK: - 测试用的 echo 服务器

private final class EchoServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "echo-server")
    private var connections: [NWConnection] = []
    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)

        listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.stateUpdateHandler = { state in
                if case .ready = state { self.echo(on: connection) }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            throw XCTSkip("echo 服务器没能启动")
        }
        port = listener.port?.rawValue ?? 0
    }

    private func echo(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { _ in
                    self.echo(on: connection)
                })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.echo(on: connection)
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}

// MARK: - 测试用的 POSIX 客户端

/// 用 POSIX socket 而不是 Network.framework 当客户端，
/// 避免「用被测对象自己测自己」。
private enum SocketClient {

    static func setTimeouts(_ fd: Int32, _ seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func connect(host: String, port: UInt16, timeout: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        setTimeouts(fd, timeout)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func isReachable(host: String, port: UInt16, timeout: Int = 3) -> Bool {
        guard let fd = connect(host: host, port: port, timeout: timeout) else { return false }
        close(fd)
        return true
    }

    /// 发 `bytes` 个字节，再把同样多的字节收回来。返回实际收到的字节数。
    static func roundTrip(host: String, port: UInt16, bytes: Int, timeout: Int = 10) -> Int? {
        guard let fd = connect(host: host, port: port, timeout: timeout) else { return nil }
        defer { close(fd) }

        let payload = [UInt8](repeating: 0x41, count: bytes)
        var sent = 0
        while sent < bytes {
            let written = payload.withUnsafeBytes { buffer -> Int in
                Darwin.send(fd, buffer.baseAddress!.advanced(by: sent), bytes - sent, 0)
            }
            if written <= 0 { return nil }
            sent += written
        }

        var received = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while received < bytes {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received += count
        }
        return received
    }

    /// 找一个非回环的 IPv4 地址，用来验证 Relay 没有监听 0.0.0.0。
    static func nonLoopbackIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: interface.ifa_name).hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if status == 0 {
                let address = String(cString: hostname)
                if !address.hasPrefix("127.") { return address }
            }
        }
        return nil
    }
}
