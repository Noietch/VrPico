import Foundation
import Darwin

/// 用户可配置项。
///
/// Native EVA-VR relay settings. The Mac helper is optional when PICO can reach
/// the EVA server directly; it is needed for USB/ADB-only access to the server.
public struct AppSettings: Codable, Equatable, Sendable {
    /// 服务器 IP 或主机名。同事的 Mac 需要能路由到这个地址（通常是公司 VPN）。
    public var serverHost: String

    /// Viser may be exposed on a different host. Old saved settings omit this
    /// field and continue to use `serverHost`.
    public var viserHost: String?

    /// EVA Console 管理页面端口，对应远端 `eva --web-port`。
    public var clientPort: Int

    /// PhysX Viser 可视化端口，对应远端 `collect.sh --viser-port`。
    public var viserPort: Int

    /// EVA WebSocket node port. PICO reaches the Mac-side relay on this port.
    public var webxrPort: Int

    /// 传给 Pico 的 `mode` 查询参数，当前只用 `ar`。
    public var webxrMode: String

    /// 指定 Pico 序列号。留空表示自动发现（仅在只有一台授权设备时可用）。
    public var picoSerial: String

    public static let defaultClientPort = 8415
    public static let defaultViserPort = 8416
    public static let defaultWebXRPort = 43876
    public static let defaultWebXRMode = "ar"
    public static let nativeToken = "eva"
    // Kept as a source-compatible alias for older settings/tests.
    public static let defaultWebXRToken = nativeToken

    public static let `default` = AppSettings(
        serverHost: "",
        viserHost: nil,
        clientPort: defaultClientPort,
        viserPort: defaultViserPort,
        webxrPort: defaultWebXRPort,
        webxrMode: defaultWebXRMode,
        picoSerial: ""
    )

    public init(
        serverHost: String,
        viserHost: String? = nil,
        clientPort: Int,
        viserPort: Int,
        webxrPort: Int,
        webxrMode: String,
        picoSerial: String
    ) {
        self.serverHost = serverHost
        self.viserHost = viserHost
        self.clientPort = clientPort
        self.viserPort = viserPort
        self.webxrPort = webxrPort
        self.webxrMode = webxrMode
        self.picoSerial = picoSerial
    }

    /// 去掉首尾空白后的主机名，避免用户粘贴时带上空格。
    public var trimmedServerHost: String {
        serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedViserHost: String {
        let host = viserHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return host.isEmpty ? trimmedServerHost : host
    }

    public var clientEndpoint: String {
        Self.formatEndpoint(host: trimmedServerHost, port: clientPort)
    }

    public var viserEndpoint: String {
        Self.formatEndpoint(host: trimmedViserHost, port: viserPort)
    }

    // MARK: - Mac 浏览器直接访问的地址

    public var clientURL: URL? {
        serverURL(host: trimmedServerHost, port: clientPort)
    }

    public var viserURL: URL? {
        serverURL(host: trimmedViserHost, port: viserPort)
    }

    /// 先校验 host 和 port，再构造 URL。IPv6 字面量需要方括号；带 zone id 的
    /// 地址还需要把 `%` 编码成 `%25`。
    private func serverURL(host: String, port: Int) -> URL? {
        guard !host.isEmpty,
              UInt16(exactly: port) != nil,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@[]")) == nil,
              !host.contains(":") || Self.isIPv6Literal(host) else {
            return nil
        }

        let urlHost = host.contains(":")
            ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]"
            : host
        return URL(string: "http://\(urlHost):\(port)/")
    }

    /// Parse the compact `host:port` form shown by the settings UI. IPv6
    /// literals use the standard bracketed form, for example `[::1]:8080`.
    public static func parseEndpoint(_ value: String) -> (host: String, port: Int)? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let host: String
        let portText: Substring
        if text.hasPrefix("[") {
            guard let closing = text.firstIndex(of: "]"),
                  text.index(after: closing) < text.endIndex,
                  text[text.index(after: closing)] == ":" else {
                return nil
            }
            host = String(text[text.index(after: text.startIndex)..<closing])
            portText = text[text.index(closing, offsetBy: 2)...]
        } else {
            guard let separator = text.lastIndex(of: ":") else { return nil }
            host = String(text[..<separator])
            portText = text[text.index(after: separator)...]
            guard !host.contains(":") else { return nil }
        }

        guard !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@[]")) == nil,
              let port = Int(portText),
              UInt16(exactly: port) != nil else {
            return nil
        }
        if host.contains(":") && !isIPv6Literal(host) { return nil }
        return (host, port)
    }

    public static func formatEndpoint(host: String, port: Int) -> String {
        guard !host.isEmpty else { return "" }
        let displayHost = host.contains(":") ? "[\(host)]" : host
        return "\(displayHost):\(port)"
    }

    private static func isIPv6Literal(_ host: String) -> Bool {
        let parts = host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts[0].isEmpty,
              parts.count == 1 || (parts.count == 2 && !parts[1].isEmpty) else {
            return false
        }

        var address = in6_addr()
        return String(parts[0]).withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }

    // MARK: - Native PICO address

    /// The native APK connects to the loopback endpoint created by adb reverse.
    public func picoNativeWebSocketURL() -> String {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = Self.defaultWebXRPort
        components.path = "/ws"
        components.queryItems = [
            URLQueryItem(name: "token", value: Self.nativeToken),
        ]
        return components.string ?? "ws://127.0.0.1:\(Self.defaultWebXRPort)/ws?token=\(Self.nativeToken)"
    }

    /// Compatibility helper for older WebXR callers. The native app does not
    /// use this URL; new code should call `picoNativeWebSocketURL()`.
    @available(*, deprecated, message: "Use picoNativeWebSocketURL() for EVA-VR")
    public func picoURL(token: String, reload: Int) -> String {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = webxrPort
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "mode", value: webxrMode),
            URLQueryItem(name: "reload", value: String(reload)),
        ]
        return components.string ?? "http://127.0.0.1:\(webxrPort)/?token=\(token)&mode=\(webxrMode)&reload=\(reload)"
    }

    // MARK: - 校验

    public enum Field: String, Sendable {
        case serverHost
        case viserHost
        case clientPort
        case viserPort
        case webxrPort
        case webxrMode
    }

    public struct ValidationIssue: Equatable, Sendable {
        public let field: Field
        public let message: String

        public init(field: Field, message: String) {
            self.field = field
            self.message = message
        }
    }

    /// 校验失败时返回全部问题，便于设置界面一次性把错误标红。
    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        let host = trimmedServerHost
        if host.isEmpty {
            issues.append(ValidationIssue(field: .serverHost, message: "请填写服务器 IP 或主机名"))
        } else if host.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            issues.append(ValidationIssue(field: .serverHost, message: "服务器地址不能包含空白字符"))
        } else if host.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@[]")) != nil {
            issues.append(ValidationIssue(field: .serverHost, message: "请只填写服务器 IP 或主机名，不要包含协议、端口或路径"))
        } else if host.contains(":") && !Self.isIPv6Literal(host) {
            issues.append(ValidationIssue(field: .serverHost, message: "IPv6 地址格式无效；如果填写的是端口，请使用下面单独的端口字段"))
        }

        let viserHost = trimmedViserHost
        if !viserHost.isEmpty,
           viserHost.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || viserHost.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#@[]")) != nil
            || (viserHost.contains(":") && !Self.isIPv6Literal(viserHost)) {
            issues.append(ValidationIssue(field: .viserHost, message: "Viser 地址无效"))
        }

        issues.append(contentsOf: Self.validatePort(clientPort, field: .clientPort, label: "Client 端口"))
        issues.append(contentsOf: Self.validatePort(viserPort, field: .viserPort, label: "Viser 端口"))
        return issues
    }

    private static func validatePort(_ port: Int, field: Field, label: String) -> [ValidationIssue] {
        guard (1...65535).contains(port) else {
            return [ValidationIssue(field: field, message: "\(label)需要 1–65535，当前是 \(port)")]
        }
        return []
    }
}
