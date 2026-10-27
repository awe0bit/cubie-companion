import SwiftUI

/// Native tab: no second custom navigation bar, no editable credential fields.
struct AppSettingsView: View {
    @EnvironmentObject private var store: BoardStore
    var body: some View {
        List {
            Section("连接") {
                NavigationLink { SettingsView() } label: {
                    Label(store.demo ? "扫码绑定开发板" : "管理扫码绑定", systemImage: "qrcode.viewfinder")
                }.accessibilityIdentifier("settings-binding")
                LabeledContent("数据连接", value: store.demo ? "演示数据" : store.live ? "实时推送" : store.stale ? "连接中断" : "正在重连")
                if !store.demo, let status = store.status {
                    LabeledContent("当前设备", value: status.hostname)
                }
                Text("曲线每秒采样，数字每 5 秒更新；切到后台后停止连接。趋势仅保留本次会话最近 2 分钟，不生成缺失数据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("应用") {
                NavigationLink { AboutView() } label: {
                    Label("关于与更新", systemImage: "arrow.triangle.2.circlepath")
                }.accessibilityIdentifier("settings-updates")
                LabeledContent("版本", value: "\(Brand.version) (\(Brand.build))")
            }
            Section {
                Label("连接凭据仅保存于本机钥匙串", systemImage: "lock.shield")
                Text("外观跟随系统；搜索与筛选在服务页右上角和左上角。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(Surface.canvas)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: BoardStore
    @State private var confirmForget = false
    @State private var showPairing = false
    @State private var error: String?

    var body: some View {
        Page {
            Card {
                VStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 32, weight: .regular))
                        .foregroundStyle(Brand.accent).accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Text(store.demo ? "连接你的开发板" : "已绑定开发板").font(.headline)
                        Text(store.demo ? "扫描电脑配对页上的二维码" : (store.status?.hostname ?? "等待设备状态"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button { showPairing = true } label: {
                        Label(store.demo ? "扫码绑定" : "扫描新设备", systemImage: "qrcode")
                            .font(.headline).foregroundStyle(Brand.onAccent)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .buttonBorderShape(.roundedRectangle(radius: Layout.cardRadius))
                    .accessibilityIdentifier("scan-pair")
                    Text("扫码后核对六位码，在电脑上批准绑定。")
                        .font(.caption).foregroundStyle(.secondary)
                }.multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
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
