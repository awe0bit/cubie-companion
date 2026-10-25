import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: BoardStore
    @State private var baseURL = ""
    @State private var apiToken = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var loadedURL = ""
    @State private var connecting = false
    @State private var error: String?
    @State private var confirmReboot = false
    @State private var confirmForget = false
    @State private var showPairing = false

    var body: some View {
        Form {
            Section {
                BrandLockup(size: 44).padding(.vertical, 4)
            }
            Section { ConnectionBanner() }
            Section {
                Button { showPairing = true } label: {
                    Label("扫码绑定开发板", systemImage: "qrcode.viewfinder")
                }.accessibilityIdentifier("scan-pair")
            } footer: {
                Text("部署 Docker 服务后，在电脑打开配对页。扫码、核对六位码并批准，即可获得独立设备凭据。下方手动配置保留用于高级接入。")
            }
            Section {
                TextField("https://board.example.com", text: $baseURL).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("设备 HTTPS 地址")
                SecureField("设备 API 令牌", text: $apiToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button {
                    connecting = true
                    error = nil
                    let credentials = ConnectionCredentials(baseURL: baseURL, apiToken: apiToken,
                        accessClientID: clientID, accessClientSecret: clientSecret)
                    Task {
                        defer { connecting = false }
                        do { try await store.connect(credentials) }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        Text("验证并连接")
                        Spacer()
                        if connecting { ProgressView() } else { Image(systemName: "arrow.right") }
                    }
                }.disabled(connecting || baseURL.isEmpty || apiToken.isEmpty)
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            } header: {
                Text("连接设备")
            } footer: {
                Text("凭据只存本机钥匙串，不进入 iCloud 同步。地址改变时会清空已填凭据，避免发往错误服务器。")
            }

            Section {
                SecureField("Access Client ID", text: $clientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Access Client Secret", text: $clientSecret)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Cloudflare Access · 按需填写")
            } footer: {
                Text("使用专门为该手机签发的服务凭据，不填写 Cloudflare 管理密钥，也不复用电脑的 SSH 凭据。")
            }

            Section("设备操作") {
                Button("重启开发板", role: .destructive) { confirmReboot = true }
                    .disabled(!store.canReboot).accessibilityIdentifier("device-reboot")
                Label("关机后需要物理重新供电，首版暂不提供关机按钮。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本机") {
                Button("查看演示界面") { store.showDemo() }
                Button("删除本机连接凭据", role: .destructive) { confirmForget = true }
                LabeledContent("版本", value: "\(Brand.version) · 开发预览")
                LabeledContent("界面", value: "原生 SwiftUI")
                NavigationLink("关于栖核", destination: AboutView())
            }
        }
        .navigationTitle("设置")
        .sheet(isPresented: $showPairing) { PairingView() }
        .onAppear {
            guard !LaunchMode.isUITesting else { return }
            do {
                if let saved = try Keychain.load() {
                    baseURL = saved.baseURL
                    loadedURL = saved.baseURL
                    apiToken = saved.apiToken
                    clientID = saved.accessClientID
                    clientSecret = saved.accessClientSecret
                }
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: baseURL) { _, value in
            guard !loadedURL.isEmpty,
                  (try? APIClient.normalizedURL(value)) != (try? APIClient.normalizedURL(loadedURL)) else { return }
            apiToken = ""
            clientID = ""
            clientSecret = ""
            loadedURL = ""
        }
        .confirmationDialog("重启开发板？", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("确认重启", role: .destructive) { Task { await store.reboot() } }
        } message: { Text("主板上的服务和远程连接会中断。断网或验证码可能延长恢复时间。") }
        .confirmationDialog("删除这台手机的连接凭据？", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("删除凭据", role: .destructive) {
                do {
                    try store.forget()
                    apiToken = ""; clientID = ""; clientSecret = ""; loadedURL = ""; baseURL = ""
                } catch { self.error = error.localizedDescription }
            }
        } message: { Text("这只清理手机钥匙串，不会撤销服务器上的令牌。丢失手机时仍需在设备端撤销凭据。") }
    }
}
