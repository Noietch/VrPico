import AppKit
import SwiftUI
import VrPicoCore


/// 带标题和说明文字的表单行。
private struct Field<Content: View>: View {
    let title: String
    let help: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            content
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Text(help)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsView: View {

    @ObservedObject var controller: AppController

    private var settings: AppSettings { controller.settings }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                serverSection
                portSection
                deviceSection
                testSection
                resetSection
            }
            .padding(20)
        }
        .frame(width: 560, height: 620)
    }

    // MARK: - 服务器

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("服务器")

            Field(
                title: "服务器 IP / 主机名",
                help: "运行远端 EVA-CLIENT 的机器。本机需要能通过 VPN、SSH 或局域网访问它。IPv6 直接填地址，不要加方括号。"
            ) {
                TextField("例如 33.229.151.180 或 h13d_8gpu", text: $controller.settings.serverHost)
            }
        }
    }

    // MARK: - 端口

    private var portSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("端口")

            Field(
                title: "Client 端口",
                help: "EVA Console 管理页面。远端用 `eva --config ... --web-port 8415` 启动，Mac 浏览器直接访问 http://服务器:8415。远端代码默认是 8080。"
            ) {
                TextField("", value: $controller.settings.clientPort, format: .number)
            }

            Field(
                title: "Viser 端口",
                help: "PhysX Viser 可视化页面。远端用 `collect.sh --viser-port 8416` 启动，Mac 浏览器直接访问 http://服务器:8416。远端代码默认是 8092。"
            ) {
                TextField("", value: $controller.settings.viserPort, format: .number)
            }

            Field(
                title: "EVA-VR 端口",
                help: "远端 EVA-CLIENT 的 WebSocket 节点端口，默认 43876。PICO 通过 ADB reverse 访问本机同端口，再由 Relay 转发到服务器。"
            ) {
                TextField("", value: $controller.settings.webxrPort, format: .number)
            }
        }
    }

    // MARK: - 设备

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("设备与工具")

            Field(
                title: "Pico 序列号（可选）",
                help: "留空表示自动发现。只连了一台授权设备时最省事；接多台的话在这里锁定，或每次连接时手动选。"
            ) {
                TextField("留空自动发现", text: $controller.settings.picoSerial)
            }

        }
    }

    // MARK: - 测试

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("连接测试")

            HStack(spacing: 8) {
                Button("测试全部") {
                    Task { await controller.testServerConnections() }
                }
                Button("测 Client") {
                    Task { await controller.testClient() }
                }
                Button("测 Viser") {
                    Task { await controller.testViser() }
                }
                Button("测 EVA-VR") {
                    Task { await controller.testWebXR() }
                }
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                StatusRow(label: "Client API", value: controller.serverStatus.client.displayText, level: level(controller.serverStatus.client))
                StatusRow(label: "Viser", value: controller.serverStatus.viser.displayText, level: level(controller.serverStatus.viser))
                StatusRow(label: "EVA-VR Server", value: controller.serverStatus.webxr.displayText, level: level(controller.serverStatus.webxr))
                StatusRow(
                    label: "ADB",
                    value: controller.adbAvailable ? "可用" : "未安装或不可执行",
                    level: controller.adbAvailable ? .ok : .failed
                )
                StatusRow(label: "Pico", value: picoText, level: picoLevel)
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var picoText: String {
        switch controller.deviceSummary {
        case .noDevices: return "未连接"
        case .ready(let device): return device.displayName
        case .multipleReady(let devices): return "\(devices.count) 台可用"
        case .unauthorized(let devices): return "未授权（\(devices.count) 台）— 请在头显里确认 USB 调试"
        case .offline(let devices): return "离线（\(devices.count) 台）— 请重新插拔"
        case .other: return "状态异常"
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

    private func level(_ result: ProbeResult) -> StatusRow.Level {
        switch result {
        case .ok: return .ok
        case .failed: return .failed
        case .checking: return .working
        case .unknown: return .idle
        }
    }

    // MARK: - 重置

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("其它")
            HStack(spacing: 8) {
                Button("恢复默认值") {
                    controller.settings = .default
                }
                .controlSize(.small)
                Text("修改会自动保存")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .padding(.bottom, 2)
    }
}
