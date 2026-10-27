import SwiftUI

struct DeviceNavigationView: View {
    var body: some View {
        NavigationStack {
            if LaunchMode.argument(after: "--preview-detail") == "binding" {
                SettingsView()
            } else {
                RuntimeScreen(route: .devices)
            }
        }
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
    @State private var selectedLED: BoardLED?
    @State private var selectedMode: String?
    private let modes = [("on", "常亮"), ("off", "关闭"), ("system", "跟随系统")]

    var body: some View {
        Page {
            if let management = store.management {
                Text("指示灯").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if management.leds.isEmpty {
                    Text("没有可管理的指示灯。电源灯如为硬件直连，无法由软件关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(management.leds) { led in
                    Card {
                        HStack {
                            Label(led.name, systemImage: "lightbulb").font(.subheadline.weight(.medium))
                            Spacer()
                            if store.operatingLEDID == led.id {
                                ProgressView().controlSize(.mini)
                                Text("正在确认").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(led.modeText).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !store.demo && store.capabilities?.ledControl == true && led.controllable {
                            HStack {
                                ForEach(modes, id: \.0) { mode, title in
                                    Button(title) { selectedLED = led; selectedMode = mode }
                                        .buttonStyle(.bordered).disabled(!store.managementReady || led.mode == mode)
                                }
                            }
                        }
                    }
                }
                if store.demo || store.capabilities?.role != "admin" {
                    Text(store.demo ? "演示数据，不会控制真实设备。" : "当前绑定为只读。控制权限需在主板端授权，App 不会自行提权。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("设备控制尚未就绪", systemImage: "switch.2",
                    description: Text(store.managementError ?? "请连接开发板并更新服务端。"))
            }
            if let error = store.managementError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .navigationTitle("设备控制")
        .confirmationDialog("确认修改指示灯？", isPresented: Binding(
            get: { selectedLED != nil }, set: { if !$0 { selectedLED = nil; selectedMode = nil } }
        ), titleVisibility: .visible) {
            if let led = selectedLED, let mode = selectedMode {
                Button("确认\(modes.first(where: { $0.0 == mode })?.1 ?? mode)") {
                    Task { await store.setLED(led, mode: mode) }
                    selectedLED = nil; selectedMode = nil
                }
            }
        } message: { Text("只修改指示灯，不会关闭开发板电源。") }
    }
}

struct ContainerDetailView: View {
    @EnvironmentObject private var store: BoardStore
    let containerID: String
    @State private var pending: String?
    private var container: BoardContainer? { store.management?.containers.first { $0.id == containerID } }
    private let titles = ["start": "启动", "restart": "重启", "stop": "停止"]
    var body: some View {
        Page {
            if let container {
                Card {
                    Label(container.name, systemImage: "shippingbox").font(.headline)
                    InfoRow(title: "状态", value: container.stateText)
                    InfoRow(title: "镜像", value: container.image)
                    InfoRow(title: "容器 ID", value: String(container.id.prefix(12)))
                }
                if !store.demo && store.capabilities?.dockerControl == true && container.controllable {
                    Card {
                        ForEach(["start", "restart", "stop"], id: \.self) { action in
                            Button(titles[action] ?? action, role: action == "stop" ? .destructive : nil) { pending = action }
                                .disabled(!store.managementReady || (action == "start" ? container.state == "running" : container.state != "running"))
                                .accessibilityIdentifier("container-\(action)")
                        }
                    }
                    Text("停止或重启会中断该应用。操作不会删除容器、镜像或数据卷。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(store.demo ? "示例容器，不会操作真实设备。" : !container.controllable ? "此容器受保护或未加入主板控制白名单。" : "当前绑定只有查看权限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("容器已不在列表", systemImage: "shippingbox", description: Text("返回服务页刷新。"))
            }
        }.navigationTitle(container?.name ?? "Docker 应用")
        .confirmationDialog("确认\(titles[pending ?? ""] ?? "操作")容器？", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible) {
            if let action = pending, let container {
                Button("确认\(titles[action] ?? action)", role: action == "stop" ? .destructive : nil) {
                    Task { await store.act(container: container, action: action) }; pending = nil
                }
            }
        } message: { Text("该应用会短暂中断，数据卷会保留。") }
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
