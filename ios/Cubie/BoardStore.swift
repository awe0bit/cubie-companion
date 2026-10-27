import Foundation
import Combine
import UIKit

enum ConnectionPhase: String { case connecting, live, polling, retrying, offline, paused, blocked }

struct ControlOperation {
    enum Phase { case sending, confirming, confirmed, uncertain, rejected }
    let kind: String
    let target: String
    let action: String
    var phase: Phase
    var message: String
    var busy: Bool { phase == .sending || phase == .confirming }
}

@MainActor
final class BoardStore: ObservableObject {
    @Published private(set) var demo = true
    @Published private(set) var endpoint = ""
    @Published private(set) var status: BoardStatus?
    @Published private(set) var services: [BoardService] = []
    @Published private(set) var servicesSampledAt: String?
    @Published private(set) var network: NetworkStatus?
    @Published private(set) var capabilities: Capabilities?
    @Published private(set) var management: ManagementStatus?
    @Published private(set) var managementError: String?
    @Published private(set) var managementLastContact: Date?
    @Published private(set) var inventory: DeviceInventory?
    @Published private(set) var inventoryError: String?
    @Published private(set) var inventoryLastContact: Date?
    @Published private(set) var lastContact: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var userRefreshing = false
    @Published private(set) var live = false
    @Published private(set) var telemetrySession = UUID().uuidString
    @Published private(set) var operating = false
    @Published private(set) var operatingLEDID: String?
    @Published private(set) var operation: ControlOperation?
    @Published private(set) var connectionPhase: ConnectionPhase = .paused
    @Published private(set) var sampleInterval = 1
    @Published private(set) var connectionRevision = 0
    @Published var error: String?
    @Published var notice: String?
    private var client: APIClient?
    private var generation = 0
    private var refreshTask: Task<Void, Never>?
    private var bundleUnsupported = false
    private var readEpoch = 0
    private var refreshFailure: Error?
    private var controlCooldownUntil: Date = .distantPast
    private var cooldownTask: Task<Void, Never>?
    private var confirmationDelays: [UInt64] = [0, 1, 2, 3, 5, 5]
    private var ledReadbacks: [String: (value: LEDReadback, received: Date)] = [:]

    #if DEBUG
    init(testClient: APIClient, confirmationDelays: [UInt64] = [0, 1, 2, 3, 5, 5]) {
        client = testClient
        self.confirmationDelays = confirmationDelays
        demo = false
        connectionPhase = .connecting
    }
    #endif

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

    var stale: Bool { !demo && ([ConnectionPhase.offline, .blocked].contains(connectionPhase) || (lastContact.map { Date().timeIntervalSince($0) > Double(max(20, sampleInterval * 3)) } ?? true)) }
    var connectionText: String {
        if demo { return "演示模式" }
        switch connectionPhase {
        case .connecting: return "连接中"
        case .live: return "实时推送"
        case .polling: return "定时刷新"
        case .retrying: return "正在重连"
        case .offline: return "等待网络"
        case .paused: return "已暂停"
        case .blocked: return "需要检查授权"
        }
    }
    var controlsCoolingDown: Bool { Date() < controlCooldownUntil }
    private var foregroundConnection: Bool { ![ConnectionPhase.paused, .offline, .blocked].contains(connectionPhase) }
    var canControl: Bool { !demo && foregroundConnection && !stale && error == nil && !operating && !controlsCoolingDown && capabilities?.serviceControl == true }
    var canReboot: Bool { !demo && !stale && error == nil && !operating && capabilities?.deviceReboot == true }
    var managementReady: Bool { !demo && foregroundConnection && !stale && !operating && error == nil && (managementLastContact.map { Date().timeIntervalSince($0) < Double(max(20, sampleInterval * 3)) } ?? false) }
    var inventoryStale: Bool { !demo && (inventoryLastContact.map { Date().timeIntervalSince($0) > 20 } ?? true) }

    func showDemo() {
        generation += 1
        pauseConnection()
        operation = nil
        operating = false
        refreshFailure = nil
        cooldownTask?.cancel()
        controlCooldownUntil = .distantPast
        telemetrySession = UUID().uuidString
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
        userRefreshing = false
        live = false
        operatingLEDID = nil
        bundleUnsupported = false
        ledReadbacks.removeAll()
        demo = true
        client = nil
        endpoint = ""
        lastContact = nil
        error = nil
        notice = nil
        capabilities = nil
        management = Demo.management
        managementLastContact = nil
        managementError = nil
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
        pauseConnection()
        operation = nil
        operating = false
        refreshFailure = nil
        cooldownTask?.cancel()
        controlCooldownUntil = .distantPast
        telemetrySession = UUID().uuidString
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
        userRefreshing = false
        live = false
        operatingLEDID = nil
        bundleUnsupported = false
        ledReadbacks.removeAll()
        client = candidate
        endpoint = bound.baseURL
        capabilities = caps
        management = nil
        managementLastContact = nil
        managementError = nil
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

    func refresh(manual: Bool = false) async {
        guard !demo else { return }
        let revision = generation
        let epoch = readEpoch
        if manual { userRefreshing = true }
        defer { if manual && revision == generation && epoch == readEpoch { userRefreshing = false } }
        // Pull-to-refresh joins an in-flight poll instead of returning without doing anything.
        if let refreshTask { await refreshTask.value; return }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        await task.value
        if revision == generation && epoch == readEpoch { refreshTask = nil }
    }

    private func loadSnapshot(_ client: APIClient) async throws -> DashboardSnapshot {
        if !bundleUnsupported {
            do { return try await client.get("snapshot") }
            catch ConnectionError.http(404) { bundleUnsupported = true }
        }
        // Compatibility only: current servers supply one bounded snapshot request.
        async let snapshot: BoardStatus = client.get("status")
        async let list: ServiceList = client.get("services")
        async let net: NetworkStatus = client.get("network")
        async let caps: Capabilities = client.get("capabilities")
        let (value, services, network, capabilities) = try await (snapshot, list, net, caps)
        var management: ManagementStatus?
        var inventory: DeviceInventory?
        if capabilities.managementInventory == true { management = try? await client.get("management") }
        if capabilities.deviceInventory == true { inventory = try? await client.get("devices") }
        return DashboardSnapshot(status: value, services: services, network: network,
                                 capabilities: capabilities, management: management, inventory: inventory)
    }

    private func performRefresh() async {
        guard !demo, !refreshing, let client else { return }
        refreshing = true
        let revision = generation
        let epoch = readEpoch
        defer { if revision == generation && epoch == readEpoch { refreshing = false } }
        do {
            let bundle = try await loadSnapshot(client)
            guard revision == generation, epoch == readEpoch, !Task.isCancelled else { return }
            try apply(bundle)
            refreshFailure = nil
        } catch {
            guard revision == generation, epoch == readEpoch, !Task.isCancelled else { return }
            refreshFailure = error
            self.error = error is URLError ? "连接暂未完成，保留上次数据。请稍后下拉重试。" : "未能刷新，保留上次数据。\(error.localizedDescription)"
        }
    }

    func pauseConnection() {
        readEpoch += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
        userRefreshing = false
        live = false
        connectionPhase = .paused
    }

    func reconnect() { refreshFailure = nil; connectionRevision += 1 }

    /// A single foreground owner. Path/power changes cancel the old structured task.
    func receiveLiveUpdates(interval: Int = 1, networkAvailable: Bool = true) async {
        guard !demo, let client else { return }
        guard networkAvailable else { pauseConnection(); connectionPhase = .offline; return }
        let revision = generation
        readEpoch += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshing = false
        userRefreshing = false
        let epoch = readEpoch
        sampleInterval = interval
        connectionPhase = .connecting
        var failures = 0
        if capabilities == nil { await refresh() }
        guard revision == generation, epoch == readEpoch, !Task.isCancelled else { return }
        if let failure = refreshFailure, ConnectionPolicy.blocksAutomaticRetry(failure) {
            connectionPhase = .blocked; return
        }
        defer { if generation == revision && readEpoch == epoch { live = false } }
        while !Task.isCancelled && generation == revision && readEpoch == epoch {
            do {
                if capabilities?.liveSnapshots == true && (interval == 1 || capabilities?.adaptiveStreaming == true) {
                    sampleInterval = capabilities?.adaptiveStreaming == true ? interval : 1
                    var received = false
                    try await client.snapshots(interval: sampleInterval, adaptive: capabilities?.adaptiveStreaming == true) { [weak self] bundle in
                        guard let self, self.generation == revision, self.readEpoch == epoch, !Task.isCancelled else { return }
                        try self.apply(bundle)
                        self.live = true
                        self.connectionPhase = .live
                        failures = 0
                        received = true
                    }
                    guard received else { throw ConnectionError.unexpectedResponse }
                    failures = 0
                    // Normal short-lease renewal is not a failed connection.
                    try await Task.sleep(nanoseconds: 200_000_000)
                } else {
                    sampleInterval = max(5, interval)
                    await refresh()
                    if let failure = refreshFailure { throw failure }
                    connectionPhase = .polling
                    failures = 0
                    try await Task.sleep(nanoseconds: UInt64(sampleInterval) * 1_000_000_000)
                }
            } catch {
                guard !Task.isCancelled, generation == revision, readEpoch == epoch else { return }
                live = false
                if ConnectionPolicy.blocksAutomaticRetry(error) {
                    connectionPhase = .blocked
                    self.error = error.localizedDescription
                    return
                }
                connectionPhase = .retrying
                failures = min(failures + 1, 5)
                // Back off before diagnostics/fallback too: never create request storms.
                let delay = ConnectionPolicy.retryDelay(failures: failures, jitter: Double.random(in: 0...1))
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                if stale { await refresh() }
            }
        }
    }

    private func apply(_ bundle: DashboardSnapshot) throws {
            let newCapabilities = bundle.capabilities
            guard newCapabilities.apiVersion == 1 else { throw ConnectionError.incompatibleAPI }
            if let previous = status.flatMap({ Display.date($0.sampledAt) }),
               let incoming = Display.date(bundle.status.sampledAt), incoming < previous { return }
            status = bundle.status
            services = bundle.services.services
            servicesSampledAt = bundle.services.sampledAt
            network = bundle.network
            capabilities = newCapabilities
            lastContact = Date()
            error = nil
            if newCapabilities.managementInventory == true {
                if let value = bundle.management {
                    // The host samples every five seconds. Never replace a confirmed
                    // hardware readback with an older sample that was already in flight.
                    ledReadbacks = ledReadbacks.filter {
                        Date().timeIntervalSince($0.value.received) < 8 && $0.value.value.isNewer(than: value.sampledAt)
                    }
                    management = value.applying(ledReadbacks.values.map { $0.value })
                    managementLastContact = Date()
                    managementError = value.dockerAvailable ? nil : "Docker 暂不可用，列表未代表全部服务。"
                } else {
                    managementLastContact = nil
                    managementError = "控制信息暂不可用，操作已暂停。"
                }
            } else {
                management = nil
                managementLastContact = nil
                managementError = "请升级主板服务端以识别 Docker 与指示灯。"
            }
            if newCapabilities.deviceInventory == true {
                if let devices = bundle.inventory {
                    inventory = devices
                    inventoryLastContact = Date()
                    inventoryError = nil
                } else {
                    inventoryError = "未能更新硬件信息，保留上次识别结果。"
                }
            } else {
                inventory = nil
                inventoryLastContact = nil
                inventoryError = "服务端尚不支持硬件识别，请升级 CoreNest Server。"
            }
    }

    func act(service: BoardService, action: String) async {
        guard serviceActionAllowed(service, action: action),
              service.id.range(of: "^[a-z-]+$", options: .regularExpression) != nil,
              client != nil else { return }
        await manage("services/\(service.id)/actions", body: ["action": action], kind: "service", target: service.id)
    }

    func serviceActionAllowed(_ service: BoardService, action: String) -> Bool {
        guard canControl, let current = services.first(where: { $0.id == service.id }), current.controllable else { return false }
        return action == "start" ? ["inactive", "failed"].contains(current.state)
            : ["stop", "restart"].contains(action) && ["active", "reloading"].contains(current.state)
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

    func setLED(_ led: BoardLED, mode: String) async {
        guard managementReady, capabilities?.ledControl == true, led.controllable,
              management?.leds.contains(where: { $0.id == led.id }) == true,
              led.id.range(of: "^[A-Za-z0-9:_-]{1,80}$", options: .regularExpression) != nil,
              ["on", "off", "system"].contains(mode) else { return }
        operatingLEDID = led.id
        let revision = generation
        defer { if revision == generation { operatingLEDID = nil } }
        await manage("leds/\(led.id)/actions", body: ["mode": mode], kind: "led", target: led.id)
    }

    func act(container: BoardContainer, action: String) async {
        guard containerActionAllowed(container, action: action),
              container.id.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              ["start", "stop", "restart"].contains(action) else { return }
        await manage("containers/\(container.id)/actions", body: ["action": action], kind: "container", target: container.id)
    }

    func containerActionAllowed(_ container: BoardContainer, action: String) -> Bool {
        guard managementReady, !controlsCoolingDown, capabilities?.dockerControl == true,
              let current = management?.containers.first(where: { $0.id == container.id }), current.controllable else { return false }
        return action == "start" ? ["created", "exited"].contains(current.state)
            : ["stop", "restart"].contains(action) && current.state == "running"
    }

    private func manage(_ path: String, body: [String: String], kind: String, target: String) async {
        guard let client else { return }
        operating = true
        notice = nil
        let revision = generation
        let action = body["action"] ?? body["mode"] ?? ""
        let baseline = kind == "service" ? servicesSampledAt : management?.sampledAt
        operation = ControlOperation(kind: kind, target: target, action: action, phase: .sending, message: "正在发送操作…")
        let lease = ControlBackgroundLease { [weak client] in client?.cancelControls() }
        defer { lease.finish(); if revision == generation { operating = false } }
        if kind != "led" {
            controlCooldownUntil = Date().addingTimeInterval(10)
            cooldownTask?.cancel()
            cooldownTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, self.generation == revision else { return }
                self.objectWillChange.send()
            }
        }
        do {
            let result: Accepted = try await client.post(path, body: body)
            guard revision == generation else { return }
            guard result.accepted else {
                operation?.phase = .rejected
                operation?.message = "设备未接受操作，请检查权限与服务状态。"
                notice = operation?.message
                return
            }
            if kind == "led", let readback = result.led, readback.id == target, readback.valid {
                ledReadbacks[target] = (readback, Date())
                management = management?.applying([readback])
                operation?.phase = .confirmed
                operation?.message = "指示灯状态已确认。"
                notice = "指示灯状态已确认。"
                return
            }
            operation?.phase = .confirming
            operation?.message = "请求已受理，等待设备状态确认…"
            let deadline = Date().addingTimeInterval(18)
            for delay in confirmationDelays {
                if delay > 0 { try await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                guard revision == generation else { return }
                if lease.expired || Task.isCancelled || Date() >= deadline { break }
                if let bundle: DashboardSnapshot = try? await client.get("snapshot", timeout: min(3, deadline.timeIntervalSinceNow)) {
                    guard revision == generation, !lease.expired else { break }
                    try apply(bundle)
                }
                if controlStateMatches(kind: kind, target: target, action: action, baseline: baseline) {
                    operation?.phase = .confirmed
                    operation?.message = action == "restart" ? "重启请求已受理，当前运行状态已确认。" : "设备实际状态已确认。"
                    notice = operation?.message
                    return
                }
            }
            operation?.phase = .uncertain
            operation?.message = "请求已受理，尚未确认最终状态。请刷新检查，不要重复提交。"
        } catch {
            guard revision == generation else { return }
            operation?.phase = .uncertain
            operation?.message = "操作结果未确认，请刷新检查，不会自动重发。\(error.localizedDescription)"
        }
        if revision == generation { notice = operation?.message }
    }

    private func controlStateMatches(kind: String, target: String, action: String, baseline: String?) -> Bool {
        if kind == "service" {
            return servicesSampledAt != baseline && services.first(where: { $0.id == target })?.state == (action == "stop" ? "inactive" : "active")
        }
        guard let management, management.sampledAt != baseline else { return false }
        if kind == "led" { return management.leds.first(where: { $0.id == target })?.mode == action }
        return management.containers.first(where: { $0.id == target })?.state == (action == "stop" ? "exited" : "running")
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

/// Only user-initiated controls receive a finite background grace period.
@MainActor
private final class ControlBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private(set) var expired = false
    init(onExpire: @escaping () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "CoreNest control") { [weak self] in
            Task { @MainActor in
                guard let self, self.identifier != .invalid else { return }
                self.expired = true
                onExpire()
                self.finish()
            }
        }
    }
    func finish() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

enum Demo {
    static let management = ManagementStatus(sampledAt: "2026-10-25T07:23:10Z",
        leds: [BoardLED(id: "demo:blue", name: "蓝色状态灯", mode: "system", controllable: false),
               BoardLED(id: "demo:green", name: "绿色指示灯", mode: "on", controllable: false)],
        containers: [BoardContainer(id: String(repeating: "a", count: 64), name: "demo-blog", image: "example/blog:stable", state: "running", controllable: false),
                     BoardContainer(id: String(repeating: "b", count: 64), name: "demo-tools", image: "example/tools:stable", state: "exited", controllable: false)], dockerAvailable: true)
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
                             cpuCores: 4, memoryBytes: status.memoryTotalBytes), devices: [
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
