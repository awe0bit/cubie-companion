import SwiftUI
import Combine
import CoreNestRuntime

@MainActor
final class RuntimeAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = RuntimeBridge.shared // Register before any JS root can emit its ready event.
        ReactNativeHostManager.shared.initialize()
        return true
    }
}

extension Notification.Name {
    static let runtimeAction = Notification.Name("corenest.runtime-action")
}

/// Host data remains authoritative. No Keychain, endpoint, API or Access credentials cross this bridge.
@MainActor
final class RuntimeBridge: ObservableObject {
    static let shared = RuntimeBridge()
    @Published private(set) var updateStage = "idle"
    @Published private(set) var runtime = "0.9.0"
    @Published private(set) var channel = "not-configured"
    @Published private(set) var launchUpdateID = ""
    @Published private(set) var embeddedLaunch = true
    @Published private(set) var emergencyLaunch = false
    @Published private(set) var readyClients = Set<String>()
    private var visibleClients = Set<String>()
    private weak var store: BoardStore?
    private var subscription: AnyCancellable?
    private var emission: Task<Void, Never>?
    private var listener: String?

    private init() {
        listener = BrownfieldMessaging.addListener { [weak self] message in
            let values = message.compactMapValues { $0 }
            Task { @MainActor [weak self] in await self?.receive(values) }
        }
    }

    func connect(_ store: BoardStore) {
        guard self.store !== store else { return }
        self.store = store
        subscription = store.objectWillChange.sink { [weak self] _ in
            self?.emission?.cancel()
            self?.emission = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000) } catch { return }
                self?.emit()
            }
        }
        emit()
    }

    static func snapshot(_ store: BoardStore) -> [String: Any] {
        var result: [String: Any] = [
            "demo": store.demo, "stale": store.stale, "refreshing": store.userRefreshing,
            "refreshAcknowledgement": true, "live": store.live, "telemetrySession": store.telemetrySession,
            "sampleInterval": store.sampleInterval, "connectionText": store.connectionText,
            "app": ["version": Brand.version, "build": Brand.build],
            "inventoryStale": store.inventoryStale,
            "services": store.services.map { service -> [String: Any] in
                ["id": service.id, "name": service.name, "unit": service.unit, "state": service.state,
                 "stateText": service.stateText, "controllable": !store.demo && service.controllable && store.capabilities?.serviceControl == true]
            },
        ]
        if let management = store.management {
            result["management"] = ["sampledAt": management.sampledAt, "dockerAvailable": management.dockerAvailable,
                "containers": management.containers.map { item -> [String: Any] in
                    ["id": item.id, "name": item.name, "image": item.image, "state": item.state,
                     "controllable": !store.demo && item.controllable && store.capabilities?.dockerControl == true]
                },
                "leds": management.leds.map { item -> [String: Any] in
                    ["id": item.id, "name": item.name, "mode": item.mode,
                     "controllable": !store.demo && item.controllable && store.capabilities?.ledControl == true]
                }]
        }
        if let operation = store.operation {
            result["operation"] = ["kind": operation.kind, "target": operation.target,
                                   "busy": operation.busy, "message": operation.message]
        }
        if let error = store.managementError { result["managementError"] = error }
        if let status = store.status { result["status"] = object(status) }
        if let inventory = store.inventory {
            result["inventory"] = ["board": object(inventory.board), "sampledAt": inventory.sampledAt,
                "devices": inventory.devices.map { ["id": $0.id, "category": $0.category, "name": $0.name, "stateText": $0.stateText] }]
        }
        if let network = store.network { result["network"] = ["campusText": network.campusText] }
        if let error = store.error { result["error"] = error }
        if let error = store.inventoryError { result["inventoryError"] = error }
        if let notice = store.notice { result["notice"] = notice }
        return result
    }

    static func json(_ store: BoardStore) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot(store)),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func object<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }

    private func emit() {
        guard let store else { return }
        let clients = visibleClients.intersection(readyClients)
        guard !clients.isEmpty else { return }
        let snapshot = Self.snapshot(store)
        for client in clients {
            BrownfieldMessaging.sendMessage(["type": "corenest.snapshot", "client": client, "snapshot": snapshot])
        }
    }

    func checkUpdate() {
        BrownfieldMessaging.sendMessage(["type": "corenest.command", "command": "check-update"])
    }

    func setVisible(_ client: String, _ visible: Bool) {
        if visible { visibleClients.insert(client); emit() }
        else { visibleClients.remove(client) }
    }
    func retire(_ client: String) { readyClients.remove(client); visibleClients.remove(client) }

    private func receive(_ message: [String: Any]) async {
        if message["type"] as? String == "corenest.ota" {
            let allowed = ["disabled", "idle", "checking", "downloading", "pending", "current", "error"]
            if let stage = message["stage"] as? String, allowed.contains(stage) { updateStage = stage }
            if let value = message["runtime"] as? String, value.count < 64 { runtime = value }
            if let value = message["channel"] as? String, value.count < 64 { channel = value }
            if let value = message["launchUpdateID"] as? String, value.isEmpty || UUID(uuidString: value) != nil { launchUpdateID = value }
            if let value = message["embeddedLaunch"] as? Bool { embeddedLaunch = value }
            if let value = message["emergencyLaunch"] as? Bool { emergencyLaunch = value }
            return
        }
        guard message["type"] as? String == "corenest.action",
              let action = message["action"] as? String, let client = message["client"] as? String,
              UUID(uuidString: client) != nil else { return }
        if action == "ready" {
            readyClients.insert(client)
            #if DEBUG
            NSLog("CORENEST_RUNTIME_READY")
            #endif
            emit()
            return
        }
        guard let store else { return }
        switch action {
        case "refresh":
            await store.refresh(manual: true)
            emit() // Also acknowledge no-op demo refreshes and coalesced requests.
            BrownfieldMessaging.sendMessage(["type": "corenest.refresh", "client": client])
        case "open.binding", "open.network", "open.about", "open.controls": break
        case "open.container":
            guard let id = message["id"] as? String, store.management?.containers.contains(where: { $0.id == id }) == true else { return }
        case "open.service":
            guard let id = message["id"] as? String, store.services.contains(where: { $0.id == id }) else { return }
        case "open.hardware":
            guard let id = message["id"] as? String, store.inventory?.devices.contains(where: { $0.id == id }) == true else { return }
        default: return // No arbitrary URLs, shell, direct requests, permissions or service mutations.
        }
        NotificationCenter.default.post(name: .runtimeAction, object: nil, userInfo: message)
    }
}

private struct RuntimeDestination: Identifiable, Hashable {
    let action: String
    let value: String
    var id: String { action + ":" + value }
}

enum RuntimeRoute: String { case overview, services, devices, developer }

struct RuntimeScreen: View {
    @EnvironmentObject private var store: BoardStore
    @ObservedObject private var bridge = RuntimeBridge.shared
    @State private var client = UUID().uuidString
    @State private var fallback = false
    @State private var destination: RuntimeDestination?
    @State private var searchQuery = ""
    @State private var serviceFilter = "全部"
    @State private var showSearch = false
    @State private var initialSnapshot: String?
    let route: RuntimeRoute
    private var ready: Bool { bridge.readyClients.contains(client) }

    private var title: String {
        switch route { case .overview: return Brand.chineseName; case .services: return "服务"; case .devices: return "设备"; case .developer: return "开发者工具" }
    }

    var body: some View {
        Group {
            if fallback {
                nativeFallback
            } else {
                GeometryReader { geometry in
                  ZStack {
                    ReactNativeView(moduleName: "main", initialProps: [
                        "route": route.rawValue, "client": client,
                        "snapshotJSON": initialSnapshot ?? RuntimeBridge.json(store),
                        "appearance": LaunchMode.argument(after: "--preview-appearance") ?? "system",
                        "disableRemoteUpdates": LaunchMode.isUITesting,
                        "bottomInset": geometry.safeAreaInsets.bottom,
                        "nativeSearch": route == .services,
                        "searchQuery": searchQuery,
                        "nativeToolbar": true,
                        "serviceFilter": serviceFilter,
                    ])
                    .ignoresSafeArea(.container, edges: .bottom)
                    if !ready {
                        ProgressView("正在载入界面").frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Surface.canvas)
                    }
                  }
                }
            }
        }
        .background(Surface.canvas.ignoresSafeArea())
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSearch) {
            ServiceSearchPanel(query: $searchQuery, filter: serviceFilter)
        }
        .onChange(of: searchQuery) { _, value in
            BrownfieldMessaging.sendMessage(["type": "corenest.command", "command": "search",
                                             "client": client, "query": String(value.prefix(128))])
        }
        .onChange(of: ready) { _, value in
            if value && route == .services {
                BrownfieldMessaging.sendMessage(["type": "corenest.command", "command": "search",
                                                 "client": client, "query": String(searchQuery.prefix(128))])
                sendFilter()
            }
        }
        .onChange(of: serviceFilter) { _, _ in sendFilter() }
        .toolbar {
            if route == .overview {
                ToolbarItem(placement: .topBarLeading) {
                    Button { destination = .init(action: store.demo ? "open.binding" : "open.network", value: "") } label: {
                        Label(store.demo ? "扫码绑定" : "网络连接", systemImage: store.demo ? "qrcode.viewfinder" : "wifi")
                    }.accessibilityIdentifier(store.demo ? "overview-connect" : "network-details")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { destination = .init(action: "open.controls", value: "") } label: { Label("设备控制", systemImage: "slider.horizontal.3") }
                            .accessibilityIdentifier("overview-controls")
                        Button { destination = .init(action: "open.network", value: "") } label: { Label("网络连接", systemImage: "wifi") }
                            .accessibilityIdentifier("network-details-menu")
                        Button { Task { await store.refresh(manual: true) } } label: { Label("刷新状态", systemImage: "arrow.clockwise") }
                    } label: { Label("快捷操作", systemImage: "ellipsis") }
                    .accessibilityIdentifier("overview-actions")
                }
            }
            if route == .services {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(["全部", "Docker", "系统"], id: \.self) { item in
                            Button { serviceFilter = item } label: {
                                if item == serviceFilter { Label(item, systemImage: "checkmark") } else { Text(item) }
                            }.accessibilityIdentifier("service-filter-" + item)
                        }
                        if !searchQuery.isEmpty { Button("清除搜索") { searchQuery = "" } }
                    } label: { Label("筛选服务", systemImage: "line.3.horizontal.decrease") }
                    .accessibilityIdentifier("service-filter")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Label("搜索服务", systemImage: "magnifyingglass") }
                        .accessibilityIdentifier("service-search-button")
                }
            }
            if route == .devices && !fallback {
                ToolbarItem(placement: .topBarLeading) {
                    Button { destination = .init(action: "open.binding", value: "") } label: {
                        Label("扫码绑定", systemImage: "qrcode.viewfinder")
                    }.accessibilityIdentifier("device-binding")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { destination = .init(action: "open.controls", value: "") } label: { Label("设备控制", systemImage: "slider.horizontal.3") }
                        .accessibilityIdentifier("device-controls")
                }
            }
        }
        .navigationDestination(item: $destination) { item in
            switch item.action {
            case "open.service": ServiceDetailView(serviceID: item.value)
            case "open.hardware": HardwareDetailView(deviceID: item.value)
            case "open.network": NetworkView()
            case "open.binding": SettingsView()
            case "open.controls": DeviceControlsView()
            case "open.container": ContainerDetailView(containerID: item.value)
            default: AboutView()
            }
        }
        .onAppear {
            // Seed each native root once. Live data uses targeted messages; hidden
            // roots must not repeatedly serialize all telemetry through initialProps.
            if initialSnapshot == nil { initialSnapshot = RuntimeBridge.json(store) }
            bridge.connect(store)
            bridge.setVisible(client, true)
        }
        .onDisappear { bridge.setVisible(client, false); if route == .developer { bridge.retire(client) } }
        .onReceive(NotificationCenter.default.publisher(for: .runtimeAction)) { event in
            guard let message = event.userInfo, message["client"] as? String == client,
                  let action = message["action"] as? String else { return }
            if action.hasPrefix("open.") {
                let value = (message["id"] as? String) ?? ""
                destination = RuntimeDestination(action: action, value: value)
            }
        }
        .task {
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            // Preserve usable local screens if the content runtime cannot start.
            if !ready { fallback = true }
        }
    }

    private func sendFilter() {
        BrownfieldMessaging.sendMessage(["type": "corenest.command", "command": "filter", "client": client, "query": serviceFilter])
    }

    @ViewBuilder private var nativeFallback: some View {
        switch route {
        case .overview: OverviewView()
        case .services: ServicesView()
        case .devices: DevicesView()
        case .developer: AboutView()
        }
    }
}

private struct ServiceSearchPanel: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @Binding var query: String
    let filter: String
    private func matches(_ values: [String]) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(term) }
    }
    private var containers: [BoardContainer] {
        filter == "系统" ? [] : (store.management?.containers ?? []).filter { matches([$0.name, $0.image]) }
    }
    private var services: [BoardService] {
        filter == "Docker" ? [] : store.services.filter { matches([$0.name, $0.unit]) }
    }
    var body: some View {
        NavigationStack {
            List {
                if !containers.isEmpty {
                    Section("Docker") {
                        ForEach(containers) { item in
                            NavigationLink { ContainerDetailView(containerID: item.id) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.subheadline.weight(.semibold))
                                    Text(item.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.accessibilityIdentifier("search-container-" + item.id)
                        }
                    }
                }
                if !services.isEmpty {
                    Section("系统") {
                        ForEach(services) { item in
                            NavigationLink { ServiceDetailView(serviceID: item.id) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.subheadline.weight(.semibold))
                                    Text(item.unit).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.accessibilityIdentifier("search-service-" + item.id)
                        }
                    }
                }
                if containers.isEmpty && services.isEmpty { Text("没有匹配的服务").foregroundStyle(.secondary) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "名称、镜像或系统单元")
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("搜索服务").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .scrollContentBackground(.hidden).background(Surface.canvas)
        }
    }
}
