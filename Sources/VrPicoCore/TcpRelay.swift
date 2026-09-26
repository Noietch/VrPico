import Foundation
import Network

public struct RelayStats: Equatable, Sendable {
    public var isRunning = false
    public var activeConnections = 0
    public var totalConnections = 0
    public var bytesToUpstream = 0
    public var bytesToClient = 0
    public var lastActivityAt: Date?

    /// 已经有字节流动，说明 Pico 那边真的连上了（页面加载或 WebSocket 建立）。
    public var hasTraffic: Bool { bytesToUpstream > 0 || bytesToClient > 0 }

    public init() {}
}

public enum RelayError: Error, LocalizedError, Equatable {
    case portInUse(UInt16)
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .portInUse(let port):
            return "本地端口 \(port) 已被占用。常见原因：VS Code Remote-SSH 的自动端口转发、或上一次没退干净。"
        case .listenerFailed(let reason):
            return "Relay 启动失败：\(reason)"
        }
    }
}

/// 把 `127.0.0.1:<listen>` 的入站连接转发到 `<upstreamHost>:<upstreamPort>`。
///
/// Why it exists: PICO can reach `127.0.0.1` through `adb reverse`, while the
/// headset cannot route to the remote EVA server directly. The relay connects
/// that local endpoint to the server-side native WebSocket node.
///
/// 只监听回环地址：绝不能绑 `0.0.0.0`，否则同网段的人都能借道访问服务器。
public final class TcpRelay {

    public let listenPort: UInt16
    public let upstreamHost: String
    public let upstreamPort: UInt16

    /// 状态变化回调，**在主线程**上触发。
    public var onStatsChanged: ((RelayStats) -> Void)?

    /// 主面板的「手柄反向」开关。每条连接上的改写器逐帧读它，所以切换在
    /// 下一帧就生效，不需要断开重连。
    public var poseFlipEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _poseFlipEnabled }
        set { lock.lock(); _poseFlipEnabled = newValue; lock.unlock() }
    }

    private let queue = DispatchQueue(label: "com.eva.vrpico.relay")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: RelayConnection] = [:]
    private var stats = RelayStats()
    private var _poseFlipEnabled = false
    private let lock = NSLock()

    public init(listenPort: UInt16, upstreamHost: String, upstreamPort: UInt16) {
        self.listenPort = listenPort
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
    }

    public var currentStats: RelayStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    // MARK: - 生命周期

    /// 启动监听，等到真正 ready（或失败）才返回。
    public func start() async throws {
        if listener != nil { return }

        let parameters = NWParameters.tcp
        // 关键：允许复用本地端点。否则 App 重启时端口还在 TIME_WAIT，
        // 绑定会失败。
        parameters.allowLocalEndpointReuse = true
        // 实时遥操作对延迟敏感，关掉 Nagle。
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
        }

        // 只绑回环地址。
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: listenPort) ?? .any
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw RelayError.listenerFailed(error.localizedDescription)
        }

        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resumeOnce: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.updateStats { $0.isRunning = true }
                    resumeOnce(.success(()))
                case .failed(let error):
                    self?.listener = nil
                    self?.updateStats { $0.isRunning = false }
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        resumeOnce(.failure(RelayError.portInUse(self?.listenPort ?? 0)))
                    } else {
                        resumeOnce(.failure(RelayError.listenerFailed(error.localizedDescription)))
                    }
                case .cancelled:
                    self?.updateStats { $0.isRunning = false }
                    resumeOnce(.failure(RelayError.listenerFailed("监听已被取消")))
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    /// 关闭监听和所有连接。App 退出前必须调用，避免残留端口。
    ///
    /// 返回前会等到监听真正进入 `.cancelled`。`cancel()` 只是投递取消请求，
    /// socket 未必已经关闭；不等的话紧接着重新绑定同一端口会报 portInUse，
    /// 表现出来就是「断开后马上重连，提示端口被占用」。
    public func stop() {
        if let listener {
            let released = DispatchSemaphore(value: 0)
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { released.signal() }
            }
            listener.cancel()
            // 正常情况下毫秒级返回；超时只是兜底，避免异常时卡住界面。
            _ = released.wait(timeout: .now() + 3)
            self.listener = nil
        }

        queue.sync {
            for connection in connections.values {
                connection.cancel()
            }
            connections.removeAll()
        }

        updateStats {
            $0.isRunning = false
            $0.activeConnections = 0
        }
    }

    // MARK: - 连接

    private func accept(_ client: NWConnection) {
        let upstream = NWConnection(
            host: NWEndpoint.Host(upstreamHost),
            port: NWEndpoint.Port(rawValue: upstreamPort) ?? .any,
            using: upstreamParameters()
        )

        let pair = RelayConnection(
            client: client,
            upstream: upstream,
            queue: queue,
            flipEnabled: { [weak self] in self?.poseFlipEnabled ?? false },
            onBytesToUpstream: { [weak self] count in
                self?.updateStats {
                    $0.bytesToUpstream += count
                    $0.lastActivityAt = Date()
                }
            },
            onBytesToClient: { [weak self] count in
                self?.updateStats {
                    $0.bytesToClient += count
                    $0.lastActivityAt = Date()
                }
            },
            onFinished: { [weak self] identifier in
                guard let self else { return }
                self.queue.async {
                    self.connections.removeValue(forKey: identifier)
                    self.updateStats { $0.activeConnections = self.connections.count }
                }
            }
        )

        let identifier = ObjectIdentifier(pair)
        queue.async {
            self.connections[identifier] = pair
            self.updateStats {
                $0.activeConnections = self.connections.count
                $0.totalConnections += 1
            }
        }

        pair.start()
    }

    private func upstreamParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
        }
        return parameters
    }

    private func updateStats(_ mutate: (inout RelayStats) -> Void) {
        lock.lock()
        mutate(&stats)
        let snapshot = stats
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onStatsChanged?(snapshot)
        }
    }
}

/// 一对 client↔upstream 连接，负责双向搬运字节。
private final class RelayConnection {

    private let client: NWConnection
    private let upstream: NWConnection
    private let queue: DispatchQueue
    private let onBytesToUpstream: (Int) -> Void
    private let onBytesToClient: (Int) -> Void
    private let onFinished: (ObjectIdentifier) -> Void

    /// Rewrites the PICO→server half of the stream: parses WebSocket frames
    /// and, while the toggle is on, turns controller poses 180°. Off means
    /// frames pass with identical payloads, so the normal path is unchanged.
    private var rewriter: WebSocketPoseRewriter

    private var isFinished = false

    init(
        client: NWConnection,
        upstream: NWConnection,
        queue: DispatchQueue,
        flipEnabled: @escaping () -> Bool,
        onBytesToUpstream: @escaping (Int) -> Void,
        onBytesToClient: @escaping (Int) -> Void,
        onFinished: @escaping (ObjectIdentifier) -> Void
    ) {
        self.client = client
        self.upstream = upstream
        self.queue = queue
        self.rewriter = WebSocketPoseRewriter(flip: flipEnabled)
        self.onBytesToUpstream = onBytesToUpstream
        self.onBytesToClient = onBytesToClient
        self.onFinished = onFinished
    }

    func start() {
        // 任一侧出错都整体收摊。
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.pipe()
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }

        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }

        client.start(queue: queue)
        upstream.start(queue: queue)
    }

    /// 两侧各起一条搬运循环。PICO→server 这一路经过改写器：可能会为了攒
    /// 一个完整帧而暂时不产出字节，也可能在开关打开时改写姿态帧。
    private func pipe() {
        pump(from: client, to: upstream, countBytes: onBytesToUpstream) { [weak self] data in
            guard let self else { return data }
            return self.rewriter.process(data)
        }
        pump(from: upstream, to: client, countBytes: onBytesToClient)
    }

    /// 从 source 读一块就写一块，写完再读下一块——这样天然形成背压，
    /// 不会因为一侧读得快而把内存撑爆。`transform` 可以改写或暂存字节；
    /// 返回空表示这块被攒下了，直接读下一块。
    private func pump(
        from source: NWConnection,
        to destination: NWConnection,
        countBytes: @escaping (Int) -> Void,
        transform: ((Data) -> Data)? = nil
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isFinished else { return }

            if let data, !data.isEmpty {
                countBytes(data.count)
                let outgoing = transform?(data) ?? data
                if outgoing.isEmpty {
                    self.pump(from: source, to: destination, countBytes: countBytes, transform: transform)
                    return
                }
                destination.send(content: outgoing, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.isFinished else { return }
                    if sendError != nil {
                        self.finish()
                        return
                    }
                    self.pump(from: source, to: destination, countBytes: countBytes, transform: transform)
                })
                return
            }

            if isComplete || error != nil {
                // 把 EOF 传给对面，让它知道可以收尾了。
                destination.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] _ in
                        self?.finish()
                    }
                )
                return
            }

            self.pump(from: source, to: destination, countBytes: countBytes, transform: transform)
        }
    }

    /// 幂等收尾：两侧都 cancel，并通知 Relay 把自己从表里摘掉。
    func finish() {
        guard !isFinished else { return }
        isFinished = true

        client.stateUpdateHandler = nil
        upstream.stateUpdateHandler = nil
        client.cancel()
        upstream.cancel()

        onFinished(ObjectIdentifier(self))
    }

    func cancel() {
        finish()
    }
}
