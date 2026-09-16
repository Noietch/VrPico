import SwiftUI
import VrPicoCore

struct SettingsView: View {

    @ObservedObject var controller: AppController

    @State private var clientAddress: String
    @State private var viserAddress: String
    @State private var clientAddressValid = true
    @State private var viserAddressValid = true

    init(controller: AppController) {
        self.controller = controller
        _clientAddress = State(initialValue: controller.settings.clientEndpoint)
        _viserAddress = State(initialValue: controller.settings.viserEndpoint)
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

            Text("填写运行 EVA-CLIENT 和 Viser 的 IP:端口。PICO、ADB 和 EVA-VR 连接由应用自动处理。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 250)
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
}
