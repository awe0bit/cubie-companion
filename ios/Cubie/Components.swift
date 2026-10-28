import SwiftUI

/// One system-owned grouping, row geometry and background for all native controls.
struct GroupedListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 48)
            .listSectionSpacing(24)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
    }
}

struct ControlStatus: View {
    let text: String
    let state: String
    var body: some View {
        Label {
            Text(text).font(.title3.weight(.semibold))
        } icon: {
            Image(systemName: ["active", "running"].contains(state) ? "checkmark.circle.fill"
                  : ["failed", "dead"].contains(state) ? "exclamationmark.circle.fill" : "pause.circle.fill")
                .foregroundStyle(["active", "running"].contains(state) ? Color.green
                                 : ["failed", "dead"].contains(state) ? Color.orange : Color.secondary)
        }.padding(.vertical, 4)
    }
}

/// Only meaningful actions are shown. Stop never competes with the main action.
struct ManagedActions: View {
    let stopped: Bool
    let identifier: String
    let allowed: (String) -> Bool
    let select: (String) -> Void

    var body: some View {
        Section {
            let action = stopped ? "start" : "restart"
            Button { select(action) } label: {
                Label(stopped ? "启动" : "重启", systemImage: stopped ? "play.fill" : "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(!allowed(action))
            .accessibilityIdentifier("\(identifier)\(action)")
        } header: { Text("管理") }
        if !stopped {
            Section {
                Button(role: .destructive) { select("stop") } label: {
                    Label {
                        Text("停止")
                    } icon: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(allowed("stop") ? Color.red : Color.secondary)
                    }
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .tint(.red)
                .disabled(!allowed("stop"))
                .accessibilityIdentifier("\(identifier)stop")
            } footer: { Text("停止后服务将不可用；不会删除数据。") }
        }
    }
}

/// A native checked menu, not three competing action buttons. The value is readback-only.
struct LEDModePicker: View {
    let name: String
    let mode: String
    let enabled: Bool
    let busy: Bool
    let identifier: String
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(selection: Binding(get: { mode }, set: { value in
                guard enabled, value != mode else { return }
                select(value)
            })) {
                Text("跟随系统").tag("system")
                Text("常亮").tag("on")
                Text("关闭").tag("off")
                if !["system", "on", "off"].contains(mode) { Text("未知").tag(mode) }
            } label: {
                Label(name, systemImage: "lightbulb")
                    .foregroundStyle(.primary)
            }
            .pickerStyle(.menu)
            .disabled(!enabled)
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(name)
            .accessibilityValue(["system": "跟随系统", "on": "常亮", "off": "关闭"][mode] ?? "未知模式")
            .accessibilityHint(busy ? "正在确认设备状态，请稍候" : "选择指示灯模式")
        }
    }
}

struct OperationFeedback: View {
    @EnvironmentObject private var store: BoardStore
    let kind: String
    let target: String

    var body: some View {
        if let operation = store.operation, operation.kind == kind, operation.target == target {
            HStack(alignment: .top, spacing: 8) {
                if operation.busy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: operation.phase == .confirmed ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(operation.phase == .confirmed ? Color.green : Color.orange)
                }
                Text(operation.message).font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("control-feedback")
            .accessibilityLabel(operation.message)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.cardInset)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
    }
}

struct Page<Content: View>: View {
    @EnvironmentObject private var store: BoardStore
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                TimelineView(.periodic(from: .now, by: 5)) { _ in ConnectionBanner() }
                content
            }.frame(maxWidth: 640).frame(maxWidth: .infinity).padding(Layout.pageInset)
        }
        .background(Surface.canvas)
        .refreshable { await store.refresh(manual: true) }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectionBanner: View {
    @EnvironmentObject private var store: BoardStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.demo {
                Label("演示数据", systemImage: "sparkles")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("demo-banner")
            } else {
                HStack(spacing: 7) {
                    Circle().fill(store.stale ? .orange : .teal).frame(width: 7, height: 7)
                    Text(store.stale ? "连接中断 · 上次数据" : "已连接")
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct Metric: View {
    let title: String
    let value: String
    let symbol: String
    var detail: String = ""
    var body: some View {
        Card {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
}

struct InfoRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let value: String
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).foregroundStyle(.secondary)
                    Text(value).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Text(title).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
        }.font(.subheadline)
    }
}

#if DEBUG
/// Network-free UI harness for the actual shared controls. Never included in the IPA.
struct ControlInteractionPreview: View {
    @State private var mode = "system"
    @State private var stopped = false
    @State private var pending: String?
    private let titles = ["start": "启动", "restart": "重启", "stop": "停止"]

    var body: some View {
        List {
            Section {
                ControlStatus(text: stopped ? "已停止" : "运行中", state: stopped ? "inactive" : "active")
            } footer: { Text("交互预览 · 仅模拟状态，不会连接或操作真实设备。") }
            ManagedActions(stopped: stopped, identifier: "preview-action-", allowed: { _ in true },
                           select: { pending = $0 })
            Section("指示灯") {
                LEDModePicker(name: "蓝色状态灯", mode: mode, enabled: true, busy: false,
                              identifier: "preview-led-mode") { mode = $0 }
            }
        }
        .modifier(GroupedListStyle())
        .navigationTitle("控件交互预览")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("确认\(titles[pending ?? ""] ?? "操作")？", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let action = pending {
                Button("确认\(titles[action] ?? action)", role: action == "stop" ? .destructive : nil) {
                    if action != "restart" { stopped = action == "stop" }
                    pending = nil
                }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { Text("仅修改预览状态。") }
    }
}
#endif
