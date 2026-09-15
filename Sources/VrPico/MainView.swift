import SwiftUI
import VrPicoCore

struct StatusRow: View {
    enum Level {
        case ok, failed, idle, working

        var color: Color {
            switch self {
            case .ok: return .green
            case .failed: return .red
            case .working: return .orange
            case .idle: return .secondary.opacity(0.4)
            }
        }
    }

    let label: String
    let value: String
    let level: Level

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(level.color)
                .frame(width: 7, height: 7)
                .offset(y: -1)

            Text(label)
                .frame(width: 96, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)

            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }
}

struct MainView: View {

    @ObservedObject var controller: AppController

    private var settings: AppSettings { controller.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().padding(.vertical, 8)

            if let devices = controller.pendingDeviceChoice {
                devicePicker(devices)
            } else {
                statusList
            }

            if !controller.adbAvailable {
                Divider().padding(.vertical, 8)
                adbMissingCallout
            }

            if let error = controller.lastError {
                Divider().padding(.vertical, 8)
                errorBox(error)
            }

            Divider().padding(.vertical, 8)

            actions
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("EVA-VR Relay")
                    .font(.system(size: 13, weight: .semibold))
                Text(settings.trimmedServerHost.isEmpty ? "未配置服务器" : settings.trimmedServerHost)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button {
                SettingsWindowController.shared.show(controller: controller)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置")
        }
    }

    // MARK: - 状态列表

    private var statusList: some View {
        VStack(alignment: .leading, spacing: 6) {
            StatusRow(
                label: "Client API",
                value: controller.serverStatus.client.displayText,
                level: level(for: controller.serverStatus.client)
            )
            StatusRow(
                label: "Viser",
                value: controller.serverStatus.viser.displayText,
                level: level(for: controller.serverStatus.viser)
            )
            StatusRow(
                label: "EVA-VR Server",
                value: controller.serverStatus.webxr.displayText,
                level: level(for: controller.serverStatus.webxr)
            )

            StatusRow(
                label: "本地 Relay",
                value: relayText,
                level: relayLevel
            )
            StatusRow(
                label: "ADB",
                value: adbText,
                level: controller.adbAvailable ? .ok : .failed
            )
            StatusRow(
                label: "Pico",
                value: picoText,
                level: picoLevel
            )
            StatusRow(
                label: NativePicoApp.displayName,
                value: controller.nativePicoStatus.displayText,
                level: nativePicoLevel
            )
            StatusRow(
                label: "ADB reverse",
                value: controller.reverseText,
                level: controller.reverseEstablished ? .ok : .idle
            )
            StatusRow(
                label: "VR 数据通道",
                value: controller.webxrChannelText,
                level: controller.relayStats.hasTraffic ? .ok : .idle
            )

            if controller.relayStats.isRunning {
                Text("连接 \(controller.relayStats.activeConnections) · 累计上行 \(byteText(controller.relayStats.bytesToUpstream)) · 下行 \(byteText(controller.relayStats.bytesToClient))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var relayText: String {
        if controller.relayStats.isRunning {
            return "运行中 · 127.0.0.1:\(controller.relayListenPort ?? settings.webxrPort)"
        }
        return "未启动"
    }

    private var relayLevel: StatusRow.Level {
        controller.relayStats.isRunning ? .ok : .idle
    }

    private var adbText: String {
        guard let location = controller.adbLocation else { return "内置组件不可用" }
        return location.sourceDescription
    }

    private var picoText: String {
        switch controller.deviceSummary {
        case .noDevices: return "未连接"
        case .ready(let device): return device.displayName
        case .multipleReady(let devices): return "\(devices.count) 台可选"
        case .unauthorized: return "未授权（请在头显确认）"
        case .offline: return "离线（请重插 USB）"
        case .other(let devices): return "状态异常（\(devices.count) 台）"
        }
    }

    private var picoLevel: StatusRow.Level {
        switch controller.deviceSummary {
        case .ready: return .ok
        case .multipleReady: return .working
        case .noDevices: return .idle
        default: return .failed
        }
    }

    private var nativePicoLevel: StatusRow.Level {
        switch controller.nativePicoStatus {
        case .installed: return .ok
        case .checking, .installing: return .working
        case .failed: return .failed
        case .unknown, .missing: return .idle
        }
    }

    private func level(for result: ProbeResult) -> StatusRow.Level {
        switch result {
        case .ok: return .ok
        case .failed: return .failed
        case .checking: return .working
        case .unknown: return .idle
        }
    }

    private func byteText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - 设备选择

    /// 多台设备时让用户选，不静默取第一台。
    private func devicePicker(_ devices: [AdbDevice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("检测到多台设备，请选择")
                .font(.system(size: 12, weight: .medium))

            ForEach(devices) { device in
                Button {
                    Task { await controller.connectAndOpenPico(serial: device.serial) }
                } label: {
                    HStack {
                        Image(systemName: "arkit")
                        Text(device.displayName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button("取消") {
                controller.pendingDeviceChoice = nil
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
    }

    // MARK: - adb 缺失

    private var adbMissingCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("App 内置的 ADB 无法运行，请重新下载或安装完整的 VrPico.app。")
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("重新检测") {
                Task { await controller.refreshEnvironment() }
            }
            .controlSize(.small)
        }
    }

    // MARK: - 错误

    private func errorBox(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: - 按钮

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(controller.busyMessage.isEmpty ? "处理中…" : controller.busyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await controller.connectAndOpenPico() }
            } label: {
                HStack {
                    Image(systemName: "visionpro")
                    Text("连接 EVA")
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isBusy)

            HStack(spacing: 8) {
                Button {
                    controller.openClient()
                } label: {
                    Label("打开 Client", systemImage: "safari")
                        .font(.system(size: 11))
                }
                .disabled(settings.trimmedServerHost.isEmpty)

                Button {
                    controller.openViser()
                } label: {
                    Label("打开 Viser", systemImage: "cube.transparent")
                        .font(.system(size: 11))
                }
                .disabled(settings.trimmedServerHost.isEmpty)
            }
            .controlSize(.small)

            HStack {
                Button("测试连接") {
                    Task { await controller.testServerConnections() }
                }
                .controlSize(.small)

                Button("断开 VR") {
                    Task { await controller.disconnectVR() }
                }
                .controlSize(.small)
                .disabled(controller.isBusy || !controller.relayStats.isRunning)

                Spacer()

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
                .disabled(controller.isBusy)
            }
        }
    }
}
