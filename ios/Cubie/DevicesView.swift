import SwiftUI

struct DeviceNavigationView: View {
    var body: some View {
        NavigationStack {
            if controlPreview {
                #if DEBUG
                ControlInteractionPreview()
                #endif
            } else if LaunchMode.argument(after: "--preview-detail") == "binding" {
                SettingsView()
            } else {
                RuntimeScreen(route: .devices)
            }
        }
    }

    private var controlPreview: Bool {
        #if DEBUG
        LaunchMode.isUITesting && LaunchMode.argument(after: "--preview-detail") == "controls"
        #else
        false
        #endif
    }
}

struct DevicesView: View {
    @EnvironmentObject private var store: BoardStore
    private let groups = [("storage", "存储"), ("usb", "USB 总线"), ("network", "网卡"), ("bluetooth", "蓝牙")]

    var body: some View {
        Page {
            NavigationLink { DeviceControlsView() } label: {
                Label("灯光与设备控制", systemImage: "switch.2")
            }.accessibilityIdentifier("device-controls")
            if let inventory = store.inventory {
                Card {
                    Label(store.status?.hostname ?? "开发板", systemImage: "cpu").font(.headline)
                    if let model = inventory.board.model { InfoRow(title: "型号标识", value: model) }
                    if let cores = inventory.board.cpuCores { InfoRow(title: "CPU 核心", value: "\(cores) 核") }
                    if let memory = inventory.board.memoryBytes { InfoRow(title: "系统内存", value: Display.bytes(memory)) }
                    if let architecture = inventory.board.architecture { InfoRow(title: "架构", value: architecture) }
                    if let kernel = inventory.board.kernel { InfoRow(title: "内核", value: kernel) }
                }
                if let error = store.inventoryError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if store.inventoryStale {
                    Text("硬件信息已过期，等待设备重新连接。")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(groups, id: \.0) { category, title in
                    let devices = inventory.devices.filter { $0.category == category }
                    if !devices.isEmpty {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                        Card {
                            VStack(spacing: 0) {
                                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                                    if index > 0 { Divider().padding(.leading, 44) }
                                    NavigationLink { HardwareDetailView(deviceID: device.id) } label: {
                                        HardwareRow(device: device)
                                    }.buttonStyle(.plain).accessibilityIdentifier("hardware-\(device.id)")
                                }
                            }
                        }
                    }
                }
                if inventory.devices.isEmpty {
                    ContentUnavailableView("暂未识别到其他设备", systemImage: "cable.connector",
                        description: Text("插入 USB 设备后下拉刷新。"))
                }
                if let date = Display.date(inventory.sampledAt) {
                    Text("识别于 \(date.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            } else if let error = store.inventoryError {
                ContentUnavailableView("硬件信息暂不可用", systemImage: "cpu", description: Text(error))
            } else {
                ContentUnavailableView("正在读取设备", systemImage: "cpu", description: Text("连接主板后自动识别。"))
            }
        }
        .navigationTitle("设备")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { SettingsView() } label: { Label("扫码绑定", systemImage: "qrcode.viewfinder") }
                    .accessibilityIdentifier("device-binding")
            }
        }
    }
}

struct DeviceControlsView: View {
    @EnvironmentObject private var store: BoardStore

    var body: some View {
        List {
            if let management = store.management {
                Section {
                if management.leds.isEmpty {
                    Text("没有可管理的指示灯。电源灯如为硬件直连，无法由软件关闭。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(management.leds) { led in
                        if !store.demo && store.capabilities?.ledControl == true && led.controllable {
                            LEDModePicker(name: led.name, mode: led.mode, enabled: store.managementReady,
                                          busy: store.operatingLEDID == led.id, identifier: "led-mode-\(led.id)") { mode in
                                Task { await store.setLED(led, mode: mode) }
                            }
                        } else {
                            LabeledContent(led.name, value: led.modeText)
                        }
                        OperationFeedback(kind: "led", target: led.id)
                }
                } header: { Text("指示灯") } footer: {
                    Text(store.demo ? "演示数据，仅展示状态，不会控制真实设备。"
                         : store.capabilities?.role != "admin" ? "当前绑定为只读。控制权限需在主板端授权。"
                         : store.capabilities?.ledControl != true ? "主板尚未启用灯光控制，或控制组件暂不可用。"
                         : !management.leds.contains(where: { $0.controllable }) ? "当前指示灯不可由软件控制。"
                         : "点按右侧模式切换，勾选表示设备已确认的模式。跟随系统会恢复系统灯光行为，不会关闭主板电源。")
                }
                if !store.demo && store.capabilities?.ledControl == true && !store.managementReady && !store.operating {
                    Section { Text("连接状态尚未确认，暂时不能修改灯光。")
                        .font(.subheadline).foregroundStyle(.secondary) }
                }
            } else {
                ContentUnavailableView("设备控制尚未就绪", systemImage: "switch.2",
                    description: Text(store.managementError ?? "请连接开发板并更新服务端。"))
            }
            if let error = store.managementError { Section { Text(error).font(.subheadline).foregroundStyle(.orange) } }
        }
        .modifier(GroupedListStyle())
        .refreshable { await store.refresh(manual: true) }
        .navigationTitle("设备控制")
    }
}

struct ContainerDetailView: View {
    @EnvironmentObject private var store: BoardStore
    let containerID: String
    @State private var pending: String?
    private var container: BoardContainer? { store.management?.containers.first { $0.id == containerID } }
    private let titles = ["start": "启动", "restart": "重启", "stop": "停止"]
    var body: some View {
        List {
            if let container {
                Section {
                    ControlStatus(text: container.stateText, state: container.state)
                    OperationFeedback(kind: "container", target: container.id)
                } footer: {
                    if store.demo || store.stale || store.error != nil { ConnectionBanner() }
                }
                if !store.demo && store.capabilities?.dockerControl == true && container.controllable {
                    ManagedActions(stopped: ["created", "exited", "dead"].contains(container.state),
                                   identifier: "container-",
                                   allowed: { store.containerActionAllowed(container, action: $0) },
                                   select: { pending = $0 })
                } else {
                    Section {
                    Text(store.demo ? "示例容器，不会操作真实设备。"
                         : store.capabilities?.role != "admin" ? "当前绑定只有查看权限。"
                         : store.capabilities?.dockerControl != true ? "主板尚未启用 Docker 控制，或控制组件暂不可用。"
                         : "此容器受保护或未加入主板控制白名单。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if store.controlsCoolingDown {
                    Section { Text("操作间隔保护中，请稍候。")
                        .font(.subheadline).foregroundStyle(.secondary) }
                }
                Section("详细信息") {
                    InfoRow(title: "镜像", value: container.image)
                    InfoRow(title: "容器 ID", value: String(container.id.prefix(12)))
                }
            } else {
                ContentUnavailableView("容器已不在列表", systemImage: "shippingbox", description: Text("返回服务页刷新。"))
            }
        }
        .modifier(GroupedListStyle())
        .refreshable { await store.refresh(manual: true) }
        .navigationTitle(container?.name ?? "Docker 应用")
        .toolbar {
            if !store.demo {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await store.refresh(manual: true) } } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }.disabled(store.refreshing).accessibilityIdentifier("container-refresh")
                }
            }
        }
        .confirmationDialog("确认\(titles[pending ?? ""] ?? "操作")\(container?.name ?? "容器")？", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let action = pending, let container {
                Button("确认\(titles[action] ?? action)", role: action == "stop" ? .destructive : nil) {
                    Task { await store.act(container: container, action: action) }; pending = nil
                }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { Text(pending == "start" ? "启动当前容器，不会删除数据卷。" : "该应用会短暂中断，数据卷会保留。") }
    }
}

private struct HardwareRow: View {
    let device: HardwareDevice
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.symbol).font(.title3).foregroundStyle(Brand.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(device.stateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(.vertical, 14).contentShape(Rectangle())
    }
}

struct HardwareDetailView: View {
    @EnvironmentObject private var store: BoardStore
    let deviceID: String
    private var device: HardwareDevice? { store.inventory?.devices.first { $0.id == deviceID } }

    var body: some View {
        Page {
            if let device {
                Card {
                    Label(device.name, systemImage: device.symbol).font(.headline)
                    InfoRow(title: "状态", value: device.stateText)
                    InfoRow(title: "类型", value: device.busText)
                    InfoRow(title: "系统节点", value: device.node)
                    if let driver = device.driver { InfoRow(title: "驱动", value: driver) }
                    if let capacity = device.capacityBytes { InfoRow(title: "设备容量", value: Display.bytes(capacity)) }
                    if let speed = device.speedMbps { InfoRow(title: "协商速率", value: String(format: "%g Mbps", speed)) }
                    if let vendor = device.vendorID, let product = device.productID {
                        InfoRow(title: "VID : PID", value: vendor+" : "+product)
                    }
                }
                if device.category == "usb", device.vendorID == "05ac" {
                    Text("USB 识别不代表已完成 iPhone 信任、配对或可以控制设备。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if device.category == "bluetooth" {
                    Text("此项表示系统已注册蓝牙控制器，不代表无线已开启或已配对外设。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if device.category == "network" {
                    NavigationLink { NetworkView() } label: { Label("查看网络状态", systemImage: "network") }
                        .font(.subheadline.weight(.medium)).accessibilityIdentifier("hardware-network-details")
                }
            } else {
                ContentUnavailableView("设备已移除", systemImage: "cable.connector.slash",
                    description: Text("识别列表已更新，请返回查看其他设备。"))
            }
        }.navigationTitle(device?.name ?? "设备详情")
    }
}
