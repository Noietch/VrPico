import AppKit
import Foundation
import SwiftUI
import VrPicoCore

enum NativePicoInstallStatus: Equatable {
    case unknown
    case checking
    case installed
    case missing
    case installing
    case failed(String)

    var displayText: String {
        switch self {
        case .unknown: return "未检测"
        case .checking: return "检测中…"
        case .installed: return "已安装"
        case .missing: return "未安装"
        case .installing: return "安装中…"
        case .failed(let message): return message
        }
    }
}

enum PendingDeviceAction {
    case connect
    case install
}

/// 全局状态与业务流程。
///
/// 所有网络/进程操作都在这里发起，视图只负责展示和调用。
@MainActor
final class AppController: ObservableObject {

    // MARK: - 配置

    @Published var settings: AppSettings {
        didSet { store.saveSettings(settings) }
    }
    // MARK: - 环境状态

    @Published private(set) var adbLocation: AdbLocation?
    @Published private(set) var adbAvailable = false
    @Published private(set) var deviceSummary: AdbDeviceSummary = .noDevices
    @Published private(set) var relayStats = RelayStats()
    @Published private(set) var serverStatus = StatusProbe.ServerReachability()
    @Published private(set) var nativePicoStatus: NativePicoInstallStatus = .unknown

    // MARK: - 流程状态

    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage = ""
    @Published private(set) var lastError: String?
    /// 非 nil 时界面弹出设备选择框。多台设备时**不静默选第一台**。
    @Published var pendingDeviceChoice: [AdbDevice]?
    @Published private(set) var pendingDeviceAction: PendingDeviceAction = .connect
    @Published private(set) var reverseEstablished = false

    private let store = AppSettingsStore()
    private var relay: TcpRelay?
    private var refreshTimer: Timer?
    private var nativeStatusSerial: String?

    /// 正在运行的连接必须保存建立时的快照。设置和设备列表会继续变化，清理时不能
    /// 再从那些可变状态推测 serial、端口或 adb 路径。
    private struct ActiveVRSession {
        let serial: String
        let serverHost: String
        let webxrPort: Int
        let adbExecutableURL: URL
        var reverseWasPreexisting: Bool
    }

    private var activeSession: ActiveVRSession?

    private var adbClient: AdbClient? {
        guard let adbLocation else { return nil }
        return AdbClient(executableURL: adbLocation.url)
    }

    // MARK: - 初始化

    init() {
        self.settings = store.loadSettings()
    }

    func start() {
        Task { await refreshEnvironment() }
        // 周期性刷新设备状态，让主界面「一直显示关键状态」。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.periodicRefresh() }
        }
    }

    /// 定时刷新。内置 adb 暂时不可用时整轮重查，恢复后界面会自己变绿。
    private func periodicRefresh() async {
        guard !isBusy else { return }
        if adbLocation == nil {
            await refreshEnvironment()
        } else {
            await refreshDevices()
        }
        await refreshReverseStatus()
    }

    // MARK: - 环境刷新

    func refreshEnvironment() async {
        let location = AdbLocator.locate()
        adbLocation = location
        guard let location else {
            adbAvailable = false
            deviceSummary = .noDevices
            return
        }
        // Older VrPico builds used a private server on 5038. Stop it before
        // touching 5037 so only one ADB daemon can own the USB headset.
        let legacyClient = AdbClient(
            executableURL: location.url,
            serverPort: AdbClient.legacyBundledServerPort
        )
        try? await legacyClient.killServer()

        let client = AdbClient(executableURL: location.url)
        adbAvailable = await client.isAvailable()
        guard adbAvailable else {
            deviceSummary = .noDevices
            return
        }
        do {
            deviceSummary = try await client.deviceSummary()
            resetNativeStatusIfDeviceChanged()
        } catch {
            deviceSummary = .noDevices
            nativePicoStatus = .unknown
            nativeStatusSerial = nil
        }
    }

    func refreshDevices() async {
        guard adbAvailable, let client = adbClient else { return }
        do {
            deviceSummary = try await client.deviceSummary()
            resetNativeStatusIfDeviceChanged()
        } catch {
            // 轮询失败不打断用户操作，只更新状态。
            deviceSummary = .noDevices
            nativePicoStatus = .unknown
            nativeStatusSerial = nil
        }
    }

    /// USB discovery may run periodically, but APK inspection is user-driven.
    /// Only clear a previous result when the attached device actually changes.
    private func resetNativeStatusIfDeviceChanged() {
        switch deviceSummary {
        case .ready(let device):
            if nativeStatusSerial != device.serial {
                nativePicoStatus = .unknown
                nativeStatusSerial = nil
            }
        case .multipleReady, .noDevices, .unauthorized, .offline, .other:
            nativePicoStatus = .unknown
            nativeStatusSerial = nil
        }
    }

    private func ensureNativePicoInstalled(serial: String, client: AdbClient) async -> Bool {
        nativeStatusSerial = serial
        nativePicoStatus = .checking
        do {
            if try await client.isPackageInstalled(serial: serial) {
                nativePicoStatus = .installed
                return true
            }
        } catch {
            nativePicoStatus = .failed("检查 EVA-PICO 失败：\(error.localizedDescription)")
            lastError = error.localizedDescription
            return false
        }

        return await installNativePico(serial: serial, client: client)
    }

    private func installNativePico(serial: String, client: AdbClient) async -> Bool {
        let apkURL = NativePicoApp.bundledAPKURL()
        guard FileManager.default.isReadableFile(atPath: apkURL.path) else {
            let message = "找不到内置 \(NativePicoApp.displayName) 安装包：\(apkURL.path)"
            nativePicoStatus = .failed("缺少安装包")
            lastError = message
            return false
        }

        nativePicoStatus = .installing
        do {
            try await client.installAPK(serial: serial, at: apkURL)
            nativePicoStatus = .installed
            return true
        } catch {
            nativePicoStatus = .failed("安装失败")
            lastError = "安装 \(NativePicoApp.displayName) 失败：\(error.localizedDescription)"
            return false
        }
    }

    private func refreshReverseStatus() async {
        guard let session = activeSession else {
            reverseEstablished = false
            return
        }
        let client = AdbClient(executableURL: session.adbExecutableURL)
        reverseEstablished = (try? await client.hasReverse(
            serial: session.serial,
            port: session.webxrPort
        )) ?? false
    }

    /// 设置界面「测试全部连接」。
    func testServerConnections() async {
        serverStatus = StatusProbe.ServerReachability()
        let result = await StatusProbe.probeServer(settings)
        serverStatus = result
    }

    func testClient() async {
        guard let url = settings.clientURL else {
            serverStatus.client = .failed(reason: "地址无效"); return
        }
        serverStatus.client = .checking
        serverStatus.client = await StatusProbe.httpStatus(url: url)
    }

    func testViser() async {
        guard let url = settings.viserURL else {
            serverStatus.viser = .failed(reason: "地址无效"); return
        }
        serverStatus.viser = .checking
        serverStatus.viser = await StatusProbe.httpStatus(url: url)
    }

    func testWebXR() async {
        serverStatus.webxr = .checking
        let port = UInt16(AppSettings.defaultWebXRPort)
        let reachable = await StatusProbe.tcpReachable(
            host: settings.trimmedServerHost,
            port: port
        )
        serverStatus.webxr = reachable ? .ok(detail: "端口可达") : .failed(reason: "连不上")
    }

    // MARK: - 派生状态

    var webxrChannelText: String {
        guard relayStats.isRunning else { return "未启动" }
        if relayStats.activeConnections == 0 { return "无连接" }
        if relayStats.hasTraffic { return "已有数据传输" }
        return "已连接，暂无数据"
    }

    var reverseText: String {
        if reverseEstablished { return "已建立" }
        switch deviceSummary {
        case .noDevices: return "无设备"
        case .unauthorized: return "未授权"
        case .offline: return "离线"
        case .other: return "不可用"
        default: return "未建立"
        }
    }

    var relayListenPort: Int? {
        relay.map { Int($0.listenPort) }
    }

    /// Whether the standalone install action can currently select a device.
    var canInstallNativePico: Bool {
        guard adbAvailable else { return false }
        switch deviceSummary {
        case .ready, .multipleReady:
            return true
        default:
            return false
        }
    }

    // MARK: - Install native EVA-VR

    /// Install the bundled APK without starting the relay or launching EVA-VR.
    /// This is useful when the headset is connected but the native app has not
    /// been installed yet, and also provides a retry path after a failed install.
    func installNativePicoOnly(serial explicitSerial: String? = nil) async {
        guard !isBusy else { return }
        lastError = nil
        pendingDeviceChoice = nil
        pendingDeviceAction = .install
        isBusy = true
        defer {
            isBusy = false
            busyMessage = ""
        }

        busyMessage = "检测 Pico…"
        await refreshEnvironment()
        guard adbAvailable, let client = adbClient else {
            lastError = "App 内置的 ADB 无法运行。请重新下载或安装完整的 VrPico.app。"
            return
        }

        let serial: String
        if let explicitSerial, !explicitSerial.isEmpty {
            serial = explicitSerial
        } else {
            switch deviceSummary {
            case .ready(let device):
                serial = device.serial
            case .multipleReady(let devices):
                pendingDeviceChoice = devices
                return
            default:
                lastError = AdbError.noReadyDevice(deviceSummary).errorDescription
                return
            }
        }

        // This is an explicit install action. Always use `adb install -r` so
        // a rebuilt APK with the same package/version can replace an older
        // bundled build instead of being skipped by the package-exists check.
        busyMessage = "安装 \(NativePicoApp.displayName)…"
        guard await installNativePico(serial: serial, client: client) else { return }
        await refreshDevices()
    }

    // MARK: - One-click native EVA-VR launch

    private func consoleRequest(
        settings: AppSettings,
        path: String,
        method: String = "GET",
        body: [String: String]? = nil
    ) async throws -> [String: Any] {
        guard let baseURL = settings.clientURL else {
            throw NSError(domain: "VrPico", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "EVA Client 地址无效",
            ])
        }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "VrPico", code: status, userInfo: [
                NSLocalizedDescriptionKey: "EVA Client API 返回 HTTP \(status)",
            ])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "VrPico", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "EVA Client API 返回了无效数据",
            ])
        }
        if json["ok"] as? Bool == false {
            throw NSError(domain: "VrPico", code: 3, userInfo: [
                NSLocalizedDescriptionKey: json["error"] as? String ?? "EVA Client 拒绝了请求",
            ])
        }
        return json
    }

    /// The console process on port 8080 and the native VR WebSocket node are
    /// separate. Start the selected native teleop component through the console
    /// API before probing 43876, so opening VrPico is enough for local use.
    private func ensureNativeTeleopStarted(_ requestedSettings: AppSettings) async throws {
        let host = requestedSettings.trimmedServerHost
        let nativePort = UInt16(AppSettings.defaultWebXRPort)
        if await StatusProbe.tcpReachable(host: host, port: nativePort) { return }

        var status = try await consoleRequest(
            settings: requestedSettings,
            path: "api/device_settings"
        )
        let processes = status["processes"] as? [String: Any]
        let operation = (status["operations"] as? [String: Any])?["teleop"] as? [String: Any]
        let operationState = operation?["state"] as? String
        let running = processes?["teleop"] is NSNull
        let starting = operationState == "queued" || operationState == "starting"

        if !running && !starting {
            _ = try await consoleRequest(
                settings: requestedSettings,
                path: "api/device_start",
                method: "POST",
                body: ["component": "teleop"]
            )
        }

        for _ in 0..<80 {
            if await StatusProbe.tcpReachable(host: host, port: nativePort) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
            status = try await consoleRequest(
                settings: requestedSettings,
                path: "api/device_settings"
            )
            if let teleop = (status["operations"] as? [String: Any])?["teleop"] as? [String: Any],
               teleop["state"] as? String == "failed" {
                throw NSError(domain: "VrPico", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: teleop["error"] as? String
                        ?? status["error"] as? String
                        ?? "EVA-VR teleop 启动失败",
                ])
            }
        }
        throw NSError(domain: "VrPico", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "EVA-VR teleop 已请求启动，但 43876 端口未就绪",
        ])
    }

    private func requiresRelay(for host: String) -> Bool {
        !["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    /// Main action: relay the remote EVA node, establish adb reverse, and
    /// launch EVA-VR on PICO. `serial` is auto-discovered when possible.
    func connectAndOpenPico(serial explicitSerial: String? = nil) async {
        guard !isBusy else { return }
        lastError = nil
        pendingDeviceChoice = nil
        pendingDeviceAction = .connect

        // 1. 校验设置
        // 整次操作都使用同一份快照，避免用户在 await 期间修改设置后得到一条
        // 主机、端口和 URL 相互不匹配的连接。
        let requestedSettings = settings
        let issues = requestedSettings.validate()
        if let first = issues.first {
            lastError = first.message
            return
        }
        isBusy = true
        defer { isBusy = false }

        let host = requestedSettings.trimmedServerHost
        let nativePort = AppSettings.defaultWebXRPort
        let webxrPort = UInt16(nativePort)

        // 2. The console is not the VR data channel. Ask it to start the native
        // teleop component, then verify the fixed EVA-VR port.
        busyMessage = "启动 EVA-VR 服务…"
        do {
            try await ensureNativeTeleopStarted(requestedSettings)
        } catch {
            serverStatus.webxr = .failed(reason: "连不上")
            lastError = error.localizedDescription
            return
        }
        serverStatus.webxr = .ok(detail: "端口可达")

        // 3. 检测 adb
        busyMessage = "检测 adb…"
        await refreshEnvironment()
        guard adbAvailable, let client = adbClient else {
            lastError = "App 内置的 ADB 无法运行。请重新下载或安装完整的 VrPico.app。"
            return
        }

        // 4~6. 找设备
        busyMessage = "查找 Pico…"
        let serial: String
        if let explicitSerial, !explicitSerial.isEmpty {
            serial = explicitSerial
        } else if !requestedSettings.picoSerial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            serial = requestedSettings.picoSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            let summary = (try? await client.deviceSummary()) ?? .noDevices
            deviceSummary = summary
            switch summary {
            case .ready(let device):
                serial = device.serial
            case .multipleReady(let devices):
                // 不静默选第一台，交给界面弹选择框。
                pendingDeviceChoice = devices
                return
            default:
                lastError = AdbError.noReadyDevice(summary).errorDescription
                return
            }
        }

        // Install only when the package is absent. Reconnects reuse the
        // installed APK and proceed directly to reverse/app launch.
        busyMessage = "检查 \(NativePicoApp.displayName)…"
        guard await ensureNativePicoInstalled(serial: serial, client: client) else {
            return
        }

        // 相同会话只需确认 reverse 仍在并重新打开页面。不能重新判断“是否预先
        // 存在”，否则第二次点击会把本 App 自己建立的映射误记成别人的。
        if var active = activeSession,
           active.serial == serial,
           active.serverHost == host,
           active.webxrPort == nativePort,
           active.adbExecutableURL == client.executableURL,
           (requiresRelay(for: host) ? relay != nil : relay == nil) {
            do {
                let sessionClient = AdbClient(executableURL: active.adbExecutableURL)
                busyMessage = "检查 ADB reverse…"
                if try await !sessionClient.hasReverse(serial: serial, port: active.webxrPort) {
                    try await sessionClient.addReverse(serial: serial, port: active.webxrPort)
                    active.reverseWasPreexisting = false
                    activeSession = active
                }
                reverseEstablished = true

                busyMessage = "启动 EVA-VR…"
                try await sessionClient.openNativeApp(
                    serial: serial,
                    serverURL: requestedSettings.picoNativeWebSocketURL()
                )
                busyMessage = ""
                await refreshDevices()
            } catch {
                lastError = error.localizedDescription
            }
            return
        }

        // 切换设备、主机或端口时先按旧会话保存的参数准确清理。
        if activeSession != nil || relay != nil {
            busyMessage = "切换 VR 连接…"
            await tearDownActiveSession()
        }

        // 7. Remote servers need a Mac-side relay. For a local EVA process,
        // adb reverse can target 43876 directly and no listener may take it.
        if requiresRelay(for: host) {
            busyMessage = "启动本地 Relay…"
            do {
                try await startRelay(host: host, port: webxrPort)
            } catch {
                lastError = error.localizedDescription
                return
            }
        }

        // 8. ADB reverse
        busyMessage = "建立 ADB reverse…"
        let reverseWasPreexisting: Bool
        do {
            // 查询失败时不能假定映射不存在，否则可能覆盖并最终删除别人的映射。
            reverseWasPreexisting = try await client.hasReverse(
                serial: serial,
                port: nativePort
            )
            if !reverseWasPreexisting {
                try await client.addReverse(serial: serial, port: nativePort)
            }
            reverseEstablished = true
        } catch {
            lastError = error.localizedDescription
            stopRelay()
            return
        }

        activeSession = ActiveVRSession(
            serial: serial,
            serverHost: host,
            webxrPort: nativePort,
            adbExecutableURL: client.executableURL,
            reverseWasPreexisting: reverseWasPreexisting
        )

        // 9. Launch native app
        busyMessage = "启动 EVA-VR…"
        do {
            try await client.openNativeApp(
                serial: serial,
                serverURL: requestedSettings.picoNativeWebSocketURL()
            )
        } catch {
            let message = error.localizedDescription
            await tearDownActiveSession()
            lastError = message
            return
        }

        busyMessage = ""
        await refreshDevices()
    }

    private func startRelay(host: String, port: UInt16) async throws {
        if let relay {
            if relay.listenPort == port,
               relay.upstreamHost == host,
               relay.upstreamPort == port {
                return
            }
            stopRelay()
        }

        let relay = TcpRelay(listenPort: port, upstreamHost: host, upstreamPort: port)
        relay.onStatsChanged = { [weak self] stats in
            Task { @MainActor in self?.relayStats = stats }
        }
        try await relay.start()
        self.relay = relay
        relayStats = relay.currentStats
    }

    // MARK: - 断开

    func disconnectVR() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        busyMessage = "正在断开…"

        await tearDownActiveSession()
        busyMessage = ""
    }

    private func tearDownActiveSession() async {
        let session = activeSession
        activeSession = nil
        reverseEstablished = false

        if let session, !session.reverseWasPreexisting {
            let client = AdbClient(executableURL: session.adbExecutableURL)
            do {
                try await client.removeReverse(serial: session.serial, port: session.webxrPort)
            } catch {
                lastError = "清理 ADB reverse 失败：\(error.localizedDescription)"
            }
        }

        stopRelay()
    }

    private func stopRelay() {
        relay?.onStatsChanged = nil
        relay?.stop()
        relay = nil
        relayStats = RelayStats()
    }

    /// App 退出前调用：关掉监听并清掉自己建立的 reverse 映射。ADB 5037
    /// is shared with the system and must stay running.
    func cleanupBeforeQuit() {
        let session = activeSession
        let adbExecutableURL = session?.adbExecutableURL ?? adbLocation?.url
        if let adbExecutableURL {
            // 退出路径上给一个同步等待的机会，否则进程先没了。
            let semaphore = DispatchSemaphore(value: 0)
            let client = AdbClient(executableURL: adbExecutableURL)
            Task.detached {
                if let session, !session.reverseWasPreexisting {
                    try? await client.removeReverse(serial: session.serial, port: session.webxrPort)
                }
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 5)
        }
        activeSession = nil
        reverseEstablished = false
        stopRelay()
    }

    // MARK: - 打开浏览器

    func openClient() {
        guard let url = settings.clientURL else { return }
        NSWorkspace.shared.open(url)

        // Opening the EVA console is also a convenient direct-entry path for
        // native PICO use. Do not make the browser button fail when no headset
        // is attached; in that case it remains a normal browser shortcut.
        guard !isBusy, !settings.trimmedServerHost.isEmpty else { return }
        switch deviceSummary {
        case .ready, .multipleReady:
            Task { await connectAndOpenPico() }
        default:
            break
        }
    }

    func openViser() {
        guard let url = settings.viserURL else { return }
        NSWorkspace.shared.open(url)
    }
}
