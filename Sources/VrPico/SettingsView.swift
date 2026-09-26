import SwiftUI
import VrPicoCore

struct SettingsView: View {

    @ObservedObject var controller: AppController

    @State private var clientAddress: String
    @State private var viserAddress: String
    @State private var vrPort: String
    @State private var vrToken: String
    @State private var clientAddressValid = true
    @State private var viserAddressValid = true
    @State private var vrPortValid = true

    init(controller: AppController) {
        self.controller = controller
        _clientAddress = State(initialValue: controller.settings.clientEndpoint)
        _viserAddress = State(initialValue: controller.settings.viserEndpoint)
        _vrPort = State(initialValue: String(controller.settings.webxrPort))
        _vrToken = State(initialValue: controller.settings.nativeTokenOverride)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("连接设置")
                .font(.system(size: 16, weight: .semibold))

            addressField(
                title: "EVA Client",
                placeholder: "127.0.0.1:8080",
                text: $clientAddress,
                valid: clientAddressValid
            )
            .onChange(of: clientAddress) { value in
                applyClientAddress(value)
            }

            addressField(
                title: "Viser",
                placeholder: "127.0.0.1:8092",
                text: $viserAddress,
                valid: viserAddressValid
            )
            .onChange(of: viserAddress) { value in
                applyViserAddress(value)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("EVA-VR 端口")
                        .font(.system(size: 12, weight: .medium))
                    TextField("43876", text: $vrPort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .frame(width: 90)
                    if !vrPortValid {
                        Text("端口需要 1–65535")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("EVA-VR token（可留空）")
                        .font(.system(size: 12, weight: .medium))
                    TextField("留空则从 Client 自动获取", text: $vrToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }
            }
            .onChange(of: vrPort) { value in
                applyPort(value)
            }
            .onChange(of: vrToken) { value in
                controller.settings.nativeTokenOverride =
                    value.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            Text("填写运行 EVA-CLIENT 和 Viser 的 IP:端口。PICO、ADB 和 EVA-VR 连接由应用自动处理。\n运行时端口的服务如果由 console 启动，token 可留空自动获取；由其他脚本启动（例如采集栈）时，请填写它的固定 token。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 330)
    }

    private func addressField(
        title: String,
        placeholder: String,
        text: Binding<String>,
        valid: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            if !valid && !text.wrappedValue.isEmpty {
                Text("请输入有效的 IP:端口")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
    }

    private func applyClientAddress(_ value: String) {
        guard let endpoint = AppSettings.parseEndpoint(value) else {
            clientAddressValid = value.isEmpty
            return
        }
        clientAddressValid = true
        controller.settings.serverHost = endpoint.host
        controller.settings.clientPort = endpoint.port

        if controller.settings.viserHost == nil {
            viserAddress = AppSettings.formatEndpoint(
                host: endpoint.host,
                port: controller.settings.viserPort
            )
        }
    }

    private func applyViserAddress(_ value: String) {
        guard let endpoint = AppSettings.parseEndpoint(value) else {
            viserAddressValid = value.isEmpty
            return
        }
        viserAddressValid = true
        controller.settings.viserHost = endpoint.host == controller.settings.trimmedServerHost
            ? nil : endpoint.host
        controller.settings.viserPort = endpoint.port
    }

    private func applyPort(_ value: String) {
        guard let port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            vrPortValid = value.isEmpty
            return
        }
        vrPortValid = true
        controller.settings.webxrPort = port
    }
}
