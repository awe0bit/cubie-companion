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
