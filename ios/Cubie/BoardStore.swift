import Foundation
import Combine

@MainActor
final class BoardStore: ObservableObject {
    @Published private(set) var demo = true
    @Published private(set) var endpoint = ""
    @Published private(set) var status: BoardStatus?
    @Published private(set) var services: [BoardService] = []
    @Published private(set) var servicesSampledAt: String?
    @Published private(set) var network: NetworkStatus?
    @Published private(set) var capabilities: Capabilities?
    @Published private(set) var inventory: DeviceInventory?
    @Published private(set) var inventoryError: String?
    @Published private(set) var inventoryLastContact: Date?
    @Published private(set) var lastContact: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var operating = false
    @Published var error: String?
    @Published var notice: String?
    private var client: APIClient?
    private var generation = 0

    init() {
        if LaunchMode.isUITesting {
            showDemo()
            return
        }
        do {
            if let credentials = try Keychain.load() {
                client = try APIClient(credentials)
                endpoint = credentials.baseURL
                demo = false
            } else {
                showDemo()
            }
        } catch {
            showDemo()
            self.error = "连接配置无法读取，请在设置中重新配对。"
        }
    }

    var stale: Bool { !demo && (lastContact.map { Date().timeIntervalSince($0) > 20 } ?? true) }
    var canControl: Bool { !demo && !stale && error == nil && !operating && capabilities?.serviceControl == true }
    var canReboot: Bool { !demo && !stale && error == nil && !operating && capabilities?.deviceReboot == true }
    var inventoryStale: Bool { !demo && (inventoryLastContact.map { Date().timeIntervalSince($0) > 20 } ?? true) }

    func showDemo() {
        generation += 1
        demo = true
        client = nil
        endpoint = ""
        lastContact = nil
        error = nil
        notice = nil
        capabilities = nil
        status = Demo.status
        services = Demo.services
        servicesSampledAt = Demo.status.sampledAt
        network = Demo.network
        inventory = Demo.inventory
        inventoryError = nil
        inventoryLastContact = nil
    }

    func connect(_ credentials: ConnectionCredentials) async throws {
        guard !LaunchMode.isUITesting else { throw ConnectionError.rejected("preview_mode") }
        let url = try APIClient.normalizedURL(credentials.baseURL)
        let bound = ConnectionCredentials(baseURL: url.absoluteString, apiToken: credentials.apiToken,
            accessClientID: credentials.accessClientID, accessClientSecret: credentials.accessClientSecret)
        let candidate = try APIClient(bound)
        let caps: Capabilities = try await candidate.get("capabilities")
        guard caps.apiVersion == 1 else { throw ConnectionError.incompatibleAPI }
        // Do not overwrite a working stored connection until authentication succeeds.
        try Keychain.save(bound)
        generation += 1
        client = candidate
        endpoint = bound.baseURL
        capabilities = caps
        demo = false
        status = nil
        services = []
        servicesSampledAt = nil
        network = nil
        lastContact = nil
        inventory = nil
        inventoryError = nil
        inventoryLastContact = nil
        error = nil
        notice = nil
        await refresh()
    }

    func forget() throws {
        try Keychain.delete()
        showDemo()
    }

    func refresh() async {
        guard !demo, !refreshing, let client else { return }
        refreshing = true
        let revision = generation
        defer { refreshing = false }
        do {
            async let snapshot: BoardStatus = client.get("status")
            async let list: ServiceList = client.get("services")
            async let net: NetworkStatus = client.get("network")
            async let caps: Capabilities = client.get("capabilities")
            let (newStatus, newServices, newNetwork, newCapabilities) = try await (snapshot, list, net, caps)
            guard revision == generation, !Task.isCancelled else { return }
            guard newCapabilities.apiVersion == 1 else { throw ConnectionError.incompatibleAPI }
            status = newStatus
            services = newServices.services
            servicesSampledAt = newServices.sampledAt
            network = newNetwork
            capabilities = newCapabilities
            lastContact = Date()
            error = nil
            if newCapabilities.deviceInventory == true {
                do {
                    let devices: DeviceInventory = try await client.get("devices")
                    guard revision == generation, !Task.isCancelled else { return }
                    inventory = devices
                    inventoryLastContact = Date()
                    inventoryError = nil
                } catch {
                    guard revision == generation, !Task.isCancelled else { return }
                    inventoryError = "未能更新硬件信息，保留上次识别结果。"
                }
            } else {
                inventory = nil
                inventoryLastContact = nil
                inventoryError = "服务端尚不支持硬件识别，请升级 CoreNest Server。"
            }
        } catch {
            guard revision == generation, !Task.isCancelled else { return }
            self.error = "未能刷新，下面保留上次数据。\(error.localizedDescription)"
        }
    }

    func act(service: BoardService, action: String) async {
        guard canControl, service.controllable, ["start", "stop", "restart"].contains(action),
              service.id.range(of: "^[a-z-]+$", options: .regularExpression) != nil,
              let client else { return }
        operating = true
        let revision = generation
        defer { operating = false }
        do {
            let result: Accepted = try await client.post("services/\(service.id)/actions", body: ["action": action])
            guard revision == generation else { return }
            notice = result.accepted ? "操作已受理，实际结果请查看刷新后的服务状态。" : "操作未被受理。"
        } catch {
            guard revision == generation else { return }
            self.error = "操作结果可能尚未确认，请先刷新，不要连续重试。\(error.localizedDescription)"
        }
        await refresh()
    }

    func reboot() async {
        guard canReboot, let client else { return }
        operating = true
        defer { operating = false }
        do {
            let result: Accepted = try await client.post("device/reboot", body: ["confirmation": "REBOOT"])
            notice = result.accepted ? "重启请求已受理。连接会短暂中断，等待设备重新上线。" : "请求未被受理。"
            lastContact = nil
        } catch {
            self.error = "重启结果未确认，请等待设备恢复后检查，不要反复提交。"
        }
    }

    func events(for service: BoardService) async throws -> [ServiceEvent] {
        guard !demo, let client else { return [] }
        guard service.id.range(of: "^[a-z-]+$", options: .regularExpression) != nil else {
            throw ConnectionError.unexpectedResponse
        }
        let result: ServiceEvents = try await client.get("services/\(service.id)/logs")
        return result.events.reversed()
    }
}

enum Demo {
    // Design fixtures only. Never sent to the board or represented as measured values.
    static let status = BoardStatus(sampledAt: "2026-10-25T07:23:10Z", hostname: "corenest-demo",
        cpuPercent: 12.4, memoryUsedBytes: 612_368_384, memoryTotalBytes: 4_026_531_840,
        diskUsedBytes: 5_368_709_120, diskTotalBytes: 31_138_512_896,
        uptimeSeconds: 19845, rxBytesPerSecond: 18432, txBytesPerSecond: 4096,
        temperatures: [Temperature(name: "cpu-thermal", celsius: 54.2)], powerWatts: nil, fanRPM: nil)
    static let services = [
        BoardService(id: "panel", unit: "1panel-core.service", name: "1Panel", state: "active", controllable: true),
        BoardService(id: "panel-agent", unit: "1panel-agent.service", name: "1Panel Agent", state: "active", controllable: true),
        BoardService(id: "monitor", unit: "beszel.service", name: "Beszel", state: "active", controllable: true),
        BoardService(id: "monitor-agent", unit: "beszel-agent.service", name: "Beszel Agent", state: "active", controllable: true),
        BoardService(id: "campus", unit: "a7s-campus-agent.timer", name: "校园网守护", state: "active", controllable: false),
        BoardService(id: "tunnel", unit: "boardd.service", name: "Cloudflare Tunnel", state: "active", controllable: false)
    ]
    static let network = NetworkStatus(sampledAt: "2026-10-25T07:23:10Z", profile: "demo-network",
        interface: "wlan0", campusStatus: "online", campusCheckedAt: "2026-10-25T07:23:10Z",
        requiresAttention: false, attemptsLastHour: 2, tunnelReady: true)
    static let inventory = DeviceInventory(sampledAt: "2026-01-01T09:41:00Z",
        board: BoardHardware(model: "Demo board", architecture: "aarch64", kernel: "Linux · 示例",
                             cpuCores: 4, memoryBytes: 4_294_967_296), devices: [
            HardwareDevice(id: "storage:demo", category: "storage", name: "SD 卡 · 示例", node: "/dev/mmcblk0",
                bus: "sd", driver: nil, state: "detected", vendorID: nil, productID: nil,
                capacityBytes: 32_000_000_000, speedMbps: nil, removable: true),
            HardwareDevice(id: "usb:demo", category: "usb", name: "USB 摄像头 · 示例", node: "1-2", bus: "usb",
                driver: "uvcvideo", state: "detected", vendorID: "1234", productID: "5678",
                capacityBytes: nil, speedMbps: 480, removable: nil),
            HardwareDevice(id: "network:demo", category: "network", name: "wlan0", node: "wlan0", bus: "wifi",
                driver: nil, state: "up", vendorID: nil, productID: nil, capacityBytes: nil, speedMbps: nil, removable: nil),
            HardwareDevice(id: "bluetooth:demo", category: "bluetooth", name: "蓝牙控制器 · 示例", node: "hci0", bus: "bluetooth",
                driver: nil, state: "detected", vendorID: nil, productID: nil, capacityBytes: nil, speedMbps: nil, removable: nil)
        ])
}
