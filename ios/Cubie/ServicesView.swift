import SwiftUI

struct ServicesView: View {
    @EnvironmentObject private var store: BoardStore
    @State private var selected: BoardService?
    @State private var pending: BoardService?
    @State private var action = "restart"
    @State private var confirm = false
    private let actionNames = ["start": "启动", "stop": "停止", "restart": "重启"]

    var body: some View {
        Page {
            Text("\(store.services.filter { $0.state == "active" }.count) / \(store.services.count) 个服务运行中")
                .font(.subheadline).foregroundStyle(.secondary)
            if store.services.isEmpty {
                ContentUnavailableView("还没有服务数据", systemImage: "square.stack.3d.up", description: Text("连接设备后自动获取。"))
            }
            ForEach(store.services) { service in
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: service.id == "tunnel" ? "point.3.connected.trianglepath.dotted" : "shippingbox")
                            .font(.title2).foregroundStyle(Brand.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(service.name).font(.headline)
                            Text(service.unit).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Circle().fill(service.state == "active" ? Color.teal : Color.orange).frame(width: 7, height: 7)
                    }
                    HStack {
                        Text(service.stateText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("查看事件") { selected = service }.font(.caption.weight(.medium)).disabled(store.demo)
                        if service.controllable {
                            Menu {
                                ForEach(["start", "restart", "stop"], id: \.self) { verb in
                                    Button(actionNames[verb] ?? verb, role: verb == "stop" ? .destructive : nil) {
                                        pending = service
                                        action = verb
                                        confirm = true
                                    }
                                }
                            } label: { Image(systemName: "ellipsis.circle").font(.title3).padding(.leading, 8) }
                                .accessibilityLabel("管理 \(service.name)").disabled(!store.canControl)
                        } else {
                            Image(systemName: "lock.shield").foregroundStyle(.secondary).accessibilityLabel("受保护的网络服务")
                        }
                    }
                }
            }
            Text(store.demo ? "演示模式不可操作真实设备。" : "校园网和隧道是远程连接的基础，首版禁止在这里停止。操作菜单需要管理员权限，且设备端必须启用控制。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("服务")
        .sheet(item: $selected) { service in
            NavigationStack { ServiceEventsView(service: service) }.environmentObject(store)
        }
        .confirmationDialog("\(actionNames[action] ?? action) \(pending?.name ?? "服务")？", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认\(actionNames[action] ?? action)", role: action == "stop" ? .destructive : nil) {
                if let service = pending { Task { await store.act(service: service, action: action) } }
            }
        } message: { Text("此操作会改变主板上的服务状态，相关网页或监控可能暂时不可用。") }
    }
}

struct ServiceEventsView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    let service: BoardService
    @State private var events: [ServiceEvent] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            Section {
                Text("仅显示本次开机的 systemd 启停事件。不读取可能包含凭据的应用原始日志。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if loading { ProgressView("读取事件…") }
            if let error { Text(error).foregroundStyle(.orange) }
            if !loading && events.isEmpty && error == nil {
                Text("暂无可显示的启停事件").foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.message)
                    Text(Display.date(event.timestamp)?.formatted(date: .abbreviated, time: .standard) ?? event.timestamp)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(service.name)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .task {
            defer { loading = false }
            do { events = try await store.events(for: service) }
            catch { self.error = error.localizedDescription }
        }
    }
}
