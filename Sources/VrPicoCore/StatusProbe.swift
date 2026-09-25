import Foundation
import Network

/// 单个探测项的结果。
public enum ProbeResult: Equatable, Sendable {
    case unknown
    case checking
    case ok(detail: String)
    case failed(reason: String)

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    public var displayText: String {
        switch self {
        case .unknown: return "未检测"
        case .checking: return "检测中…"
        case .ok(let detail): return detail
        case .failed(let reason): return reason
        }
    }
}

public enum StatusProbe {

    // MARK: - TCP 可达性

    /// 探测 `host:port` 能否建立 TCP 连接。
    ///
    /// 用于主流程的前置校验：服务器不可达时应该立刻停下，而不是先建
    /// Relay 再让 Pico 白等。
    public static func tcpReachable(
        host: String,
        port: UInt16,
        timeout: TimeInterval = 5
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.eva.vrpico.probe")
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)

            var resumed = false
            let finish: (Bool) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: result)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                case .waiting:
                    // 连接被拒或路由不可达都会停在这里。对「探测可达性」这个
                    // 用途来说，waiting 就等于不可用，直接快速失败，不必等满超时。
                    finish(false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// 探测 WebSocket 服务能否正常完成握手。
    ///
    /// 裸 TCP 探测对这个用途是不够的：连接建立后立刻关闭会留下一条没有
    /// WebSocket 握手的半开连接，node 端每次都会记一条 `400 Bad Request`，
    /// 在轮询下把日志刷满。这里发一个真正的握手请求，再主动断开。
    ///
    /// 101 表示握手成功；200 表示服务在但不接受当前路径（node 会用 200 拒掉
    /// 非 `/ws` 请求）。两者都算「服务可用」。
    ///
    /// `acceptAuthChallenge` 额外把 401 也算作可用：调用方在还没拿到 token 时
    /// 用它判断「对面是不是真的 node」。401 是 node 的鉴权响应，恰好证明它
    /// 在那儿；而任意一个陌生监听者不会回 401。
    public static func webSocketReachable(
        url: URL,
        timeout: TimeInterval = 5,
        acceptAuthChallenge: Bool = false
    ) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        request.setValue(
            "dGhlIHNhbXBsZSBub25jZQ==", forHTTPHeaderField: "Sec-WebSocket-Key"
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if acceptAuthChallenge && http.statusCode == 401 { return true }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - HTTP 状态

    /// 探测 HTTP 服务。
    ///
    /// **显式禁用代理**：本机装了本地代理（github 的 ProxyCommand 走
    /// 127.0.0.1:10808）时，URLSession 默认会读系统代理设置，把内网/VPN
    /// 地址也拐进代理，导致明明能直连却报错。
    public static func httpStatus(url: URL, timeout: TimeInterval = 8) async -> ProbeResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        // 只关心页面在不在，不需要跟随跳转去把整页拉下来。
        let session = URLSession(configuration: configuration)

        defer { session.invalidateAndCancel() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(reason: "响应不是 HTTP")
            }
            if (200...399).contains(http.statusCode) {
                return .ok(detail: "HTTP \(http.statusCode)")
            }
            return .failed(reason: "HTTP \(http.statusCode)")
        } catch let error as URLError {
            return .failed(reason: describe(error))
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cannotFindHost: return "找不到主机"
        case .cannotConnectToHost: return "连接被拒绝"
        case .timedOut: return "超时"
        case .notConnectedToInternet: return "没有网络"
        case .networkConnectionLost: return "连接中断"
        default: return error.localizedDescription
        }
    }

    // MARK: - 组合探测

    /// 设置界面「测试全部连接」用的一次性探测。
    public struct ServerReachability: Sendable {
        public var client: ProbeResult = .unknown
        public var viser: ProbeResult = .unknown
        public var webxr: ProbeResult = .unknown

        public init() {}
    }

    public static func probeServer(_ settings: AppSettings) async -> ServerReachability {
        var result = ServerReachability()
        let host = settings.trimmedServerHost
        guard !host.isEmpty else {
            let missing = ProbeResult.failed(reason: "未填写服务器地址")
            result.client = missing
            result.viser = missing
            result.webxr = missing
            return result
        }

        // 三个探测互不依赖，并发跑，避免串行等待。
        async let clientTask: ProbeResult = {
            guard let url = settings.clientURL else { return .failed(reason: "地址无效") }
            return await httpStatus(url: url)
        }()
        async let viserTask: ProbeResult = {
            guard let url = settings.viserURL else { return .failed(reason: "地址无效") }
            return await httpStatus(url: url)
        }()
        async let webxrTask: ProbeResult = {
            let port = UInt16(AppSettings.defaultWebXRPort)
            let reachable = await tcpReachable(host: host, port: port)
            return reachable ? .ok(detail: "端口可达") : .failed(reason: "连不上")
        }()

        result.client = await clientTask
        result.viser = await viserTask
        result.webxr = await webxrTask
        return result
    }
}
