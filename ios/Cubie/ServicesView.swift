import SwiftUI

struct ServicesView: View {
    @EnvironmentObject private var store: BoardStore
    private var running: Int { store.services.filter { $0.state == "active" }.count }
    private var sortedServices: [BoardService] {
        store.services.sorted {
            if ($0.state == "active") != ($1.state == "active") { return $0.state != "active" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Page {
            if let management = store.management, !management.containers.isEmpty {
                Text("Docker 应用").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Card {
                    ForEach(management.containers) { container in
                        NavigationLink { ContainerDetailView(containerID: container.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(container.name).font(.subheadline.weight(.semibold))
                                    Text(container.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(container.stateText).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if store.services.isEmpty {
                ContentUnavailableView("暂无服务数据", systemImage: "square.stack.3d.up", description: Text("连接设备后下拉刷新。"))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(running)").font(.largeTitle.weight(.semibold)).monospacedDigit()
                    Text("/ \(store.services.count) 运行中").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text("系统服务").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 2)
                Card {
                    VStack(spacing: 0) {
                        ForEach(Array(sortedServices.enumerated()), id: \.element.id) { index, service in
                            if index > 0 { Divider().padding(.leading, 44) }
                            NavigationLink { ServiceDetailView(serviceID: service.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: service.id == "tunnel" ? "network" : "shippingbox")
                                        .font(.title3).foregroundStyle(Brand.accent).frame(width: 32)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(service.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                        Text(service.stateText).font(.caption)
                                            .foregroundStyle(service.state == "active" ? Color.secondary : Color.orange)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }.padding(.vertical, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("service-\(service.id)")
                        }
                    }
                }
            }
        }.navigationTitle("服务")
    }
}

struct ServiceDetailView: View {
    @EnvironmentObject private var store: BoardStore
    let serviceID: String
    @State private var pendingAction: String?
    private var service: BoardService? { store.services.first { $0.id == serviceID } }
    private let actions = ["start": "启动", "stop": "停止", "restart": "重启"]

    var body: some View {
        List {
            if let service {
                Section {
                    ControlStatus(text: service.stateText, state: service.state)
                    OperationFeedback(kind: "service", target: service.id)
                } footer: {
                    if store.demo || store.stale || store.error != nil { ConnectionBanner() }
                }
                if !store.demo && store.capabilities?.serviceControl == true && service.controllable {
                    ManagedActions(stopped: ["inactive", "failed"].contains(service.state),
                                   identifier: "service-action-",
                                   allowed: { store.serviceActionAllowed(service, action: $0) },
                                   select: { pendingAction = $0 })
                    if store.controlsCoolingDown {
                        Section { Text("操作间隔保护中，请稍候。启动、停止与重启共用 10 秒冷却。")
                            .font(.subheadline).foregroundStyle(.secondary) }
                    } else if store.stale || store.error != nil {
                        Section { Text("连接状态尚未确认，操作已暂停。请恢复连接后重试。")
                            .font(.subheadline).foregroundStyle(.orange) }
                    }
                } else {
                    Section {
                    Text(store.demo ? "示例服务，不会操作真实设备。"
                         : !service.controllable ? "此服务受保护，不能从 App 启停。"
                         : store.capabilities?.role != "admin" ? "当前绑定为只读，需要主板端授予管理权限。"
                         : "主板尚未启用系统服务控制，或控制组件暂不可用。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section("详细信息") {
                    InfoRow(title: "系统单元", value: service.unit)
                    if let sampled = store.servicesSampledAt, let date = Display.date(sampled) {
                        InfoRow(title: "采样时间", value: date.formatted(date: .omitted, time: .standard))
                    }
                }
            } else {
                ContentUnavailableView("服务已不在当前列表", systemImage: "shippingbox", description: Text("请返回服务列表刷新。"))
            }
        }
        .modifier(GroupedListStyle())
        .refreshable { await store.refresh(manual: true) }
        .navigationTitle(service?.name ?? "服务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.demo {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refresh(manual: true) } } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }.disabled(store.refreshing).accessibilityIdentifier("service-refresh")
                }
            }
        }
        .alert("确认\(actions[pendingAction ?? ""] ?? "操作")\(service?.name ?? "服务")？", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        )) {
            if let action = pendingAction, let service {
                Button("确认\(actions[action] ?? action)", role: action == "stop" ? .destructive : nil) {
                    Task { await store.act(service: service, action: action) }
                    pendingAction = nil
                }
            }
            Button("取消", role: .cancel) { pendingAction = nil }
        } message: { Text(pendingAction == "start" ? "启动当前服务。" : "相关服务会短暂中断，请确认没有正在执行的重要任务。") }
    }
}
