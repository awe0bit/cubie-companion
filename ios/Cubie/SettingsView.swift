import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: BoardStore
    @State private var confirmForget = false
    @State private var showPairing = false
    @State private var error: String?

    var body: some View {
        Page {
            Card {
                VStack(spacing: 20) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 48, weight: .regular))
                        .foregroundStyle(Brand.accent).accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text(store.demo ? "连接你的开发板" : "已绑定开发板").font(.title2.weight(.semibold))
                        Text(store.demo ? "扫描电脑配对页上的二维码" : (store.status?.hostname ?? "等待设备状态"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button { showPairing = true } label: {
                        Label(store.demo ? "扫码绑定" : "扫描新设备", systemImage: "qrcode")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .buttonBorderShape(.roundedRectangle(radius: Layout.cardRadius))
                    .accessibilityIdentifier("scan-pair")
                    Text("扫码后核对六位码，在电脑上批准绑定。")
                        .font(.caption).foregroundStyle(.secondary)
                }.multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            if !store.demo {
                Card {
                    InfoRow(title: "设备地址", value: store.endpoint)
                    Button("解除本机绑定", role: .destructive) { confirmForget = true }
                        .font(.subheadline.weight(.medium)).accessibilityIdentifier("forget-device")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("凭据仅保存在本机钥匙串。")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 4)
        }
        .navigationTitle("绑定")
        .sheet(isPresented: $showPairing) { PairingView() }
        .confirmationDialog("解除这台 iPhone 的绑定？", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("解除绑定", role: .destructive) {
                do { try store.forget() }
                catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("会删除本机凭据，不影响主板运行。服务器上的设备授权需在设备端撤销。")
        }
    }
}
