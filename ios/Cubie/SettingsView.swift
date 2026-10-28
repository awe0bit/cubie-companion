import SwiftUI

/// A system grouped list; explanations live in their corresponding detail pages.
struct AppSettingsView: View {
    @EnvironmentObject private var store: BoardStore
    var body: some View {
        List {
            Section("设备连接") {
                NavigationLink { SettingsView() } label: {
                    SettingsRow("设备绑定", symbol: "qrcode", color: .blue,
                                value: store.demo ? "未绑定" : "已绑定")
                }.accessibilityIdentifier("settings-binding")
                NavigationLink { ConnectionSettingsView() } label: {
                    SettingsRow("数据连接", symbol: "antenna.radiowaves.left.and.right", color: .green,
                                value: connectionState(store))
                }.accessibilityIdentifier("settings-connection")
            }
            Section("应用") {
                NavigationLink { AboutView() } label: {
                    SettingsRow("关于与更新", symbol: "gearshape.fill", color: .gray, value: Brand.version)
                }.accessibilityIdentifier("settings-updates")
                NavigationLink { PrivacySettingsView() } label: {
                    SettingsRow("隐私与安全", symbol: "hand.raised.fill", color: .blue)
                }.accessibilityIdentifier("settings-privacy")
            }
        }
        .modifier(GroupedListStyle())
        .navigationTitle("设置").navigationBarTitleDisplayMode(.large)
    }
}

private struct SettingsRow: View {
    let title: String
    let symbol: String
    let color: Color
    var value: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, symbol: String, color: Color, value: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.value = value
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    if let value { Text(value).foregroundStyle(.secondary).font(.subheadline) }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                Text(title).foregroundStyle(.primary).layoutPriority(1)
                Spacer(minLength: 8)
                if let value { Text(value).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .font(.body)
        .padding(.vertical, 3)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 40 }
    }
}

@MainActor
private func connectionState(_ store: BoardStore) -> String {
    store.connectionText
}

private struct ConnectionSettingsView: View {
    @EnvironmentObject private var store: BoardStore
    @AppStorage("connection.economy.v1") private var economy = false

    var body: some View {
        List {
            Section {
                LabeledContent("连接状态", value: connectionState(store))
                if !store.demo, let status = store.status {
                    LabeledContent("当前设备", value: status.hostname)
                }
                NavigationLink { NetworkView() } label: {
                    Label("网络详情", systemImage: "wifi")
                }.accessibilityIdentifier("settings-network")
                if !store.demo {
                    Button("重新连接") { store.reconnect() }.accessibilityIdentifier("connection-reconnect")
                }
            } footer: {
                Text("仅在应用前台接收数据，切到后台后暂停连接。")
            }
            Section {
                Toggle("节能刷新", isOn: $economy).accessibilityIdentifier("connection-economy")
                LabeledContent("曲线采样", value: store.demo ? "演示数据" : "每 \(store.sampleInterval) 秒")
                LabeledContent("数字更新", value: "至少间隔 5 秒")
                LabeledContent("趋势保留", value: "最近 2 分钟")
            } header: {
                Text("实时数据")
            } footer: {
                Text("自动模式：Wi-Fi 概览每秒，蜂窝概览、服务与设备每 5 秒，设置每 15 秒刷新。开启节能刷新，或系统低电量、低数据模式、手机过热时，每 15 秒刷新。后台暂停；趋势仅保留本次会话的数据，连接中断时保留缺口。")
            }
        }
        .modifier(GroupedListStyle())
        .navigationTitle("数据连接").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacySettingsView: View {
    var body: some View {
        List {
            Section {
                Label("凭据保存在本机钥匙串", systemImage: "key.fill")
            } header: {
                Text("设备凭据")
            } footer: {
                Text("解除绑定会删除这台 iPhone 上的凭据，不影响主板运行。手机丢失后仍需在服务端撤销授权。")
            }
            Section {
                Label("不含广告与第三方统计 SDK", systemImage: "hand.raised.fill")
                Label("只在前台接收设备数据", systemImage: "pause.circle.fill")
            } header: {
                Text("数据使用")
            } footer: {
                Text("远程连接经过你配置的 Cloudflare 服务。")
            }
        }
        .modifier(GroupedListStyle())
        .navigationTitle("隐私与安全").navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: BoardStore
    @State private var confirmForget = false
    @State private var showPairing = false
    @State private var error: String?

    var body: some View {
        List {
            if store.demo {
                Section {
                    Label("连接你的开发板", systemImage: "qrcode.viewfinder").font(.headline)
                    Button { showPairing = true } label: {
                        Label("扫码绑定", systemImage: "qrcode")
                            .foregroundStyle(Brand.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("scan-pair")
                } footer: {
                    Text("扫码后核对六位码，在电脑上批准绑定。")
                }
            } else {
                Section("当前设备") {
                    Label(store.status?.hostname ?? "已绑定开发板", systemImage: "cpu")
                        .font(.headline).textSelection(.enabled)
                    InfoRow(title: "连接状态", value: store.connectionText)
                    InfoRow(title: "设备地址", value: store.endpoint)
                }
                Section {
                    Button { showPairing = true } label: {
                        Label("更换绑定设备…", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    }.accessibilityIdentifier("scan-pair")
                } footer: { Text("扫描另一台设备的二维码，批准后替换当前绑定。") }
                Section {
                    Button("解除本机绑定", role: .destructive) { confirmForget = true }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .accessibilityIdentifier("forget-device")
                } footer: { Text("仅移除本机钥匙串中的凭据，不影响主板运行。") }
            }
            if let error { Section { Text(error).font(.subheadline).foregroundStyle(.orange) } }
        }
        .modifier(GroupedListStyle())
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
