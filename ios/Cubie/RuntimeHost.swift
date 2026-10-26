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
    @Published private(set) var runtime = "0.7.0"
    @Published private(set) var channel = "not-configured"
    @Published private(set) var readyClients = Set<String>()
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
            "demo": store.demo, "stale": store.stale, "refreshing": store.refreshing,
            "inventoryStale": store.inventoryStale,
            "services": store.services.map { ["id": $0.id, "name": $0.name, "unit": $0.unit, "state": $0.state, "stateText": $0.stateText] },
        ]
        if let management = store.management { result["management"] = object(management) }
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
        BrownfieldMessaging.sendMessage(["type": "corenest.snapshot", "snapshot": Self.snapshot(store)])
    }

    func checkUpdate() {
        BrownfieldMessaging.sendMessage(["type": "corenest.command", "command": "check-update"])
    }

    private func receive(_ message: [String: Any]) async {
        if message["type"] as? String == "corenest.ota" {
            let allowed = ["disabled", "idle", "checking", "downloading", "pending", "current", "error"]
            if let stage = message["stage"] as? String, allowed.contains(stage) { updateStage = stage }
            if let value = message["runtime"] as? String, value.count < 64 { runtime = value }
            if let value = message["channel"] as? String, value.count < 64 { channel = value }
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
        case "refresh": await store.refresh()
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

struct RuntimeScreen: View {
    @EnvironmentObject private var store: BoardStore
    @ObservedObject private var bridge = RuntimeBridge.shared
    @State private var client = UUID().uuidString
    @State private var fallback = false
    @State private var destination: RuntimeDestination?
    let route: AppTab
    private var ready: Bool { bridge.readyClients.contains(client) }

    private var title: String {
        switch route { case .overview: return Brand.chineseName; case .services: return "服务"; case .devices: return "设备" }
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
                        "snapshotJSON": RuntimeBridge.json(store),
                        "appearance": LaunchMode.argument(after: "--preview-appearance") ?? "system",
                        "disableRemoteUpdates": LaunchMode.isUITesting,
                        "bottomInset": geometry.safeAreaInsets.bottom,
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
        .toolbar {
            if route == .devices && !fallback {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { destination = .init(action: "open.binding", value: "") } label: {
                        Label("扫码绑定", systemImage: "qrcode.viewfinder")
                    }.accessibilityIdentifier("device-binding")
                }
            }
            if route == .overview {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { AboutView() } label: { Label("关于与更新", systemImage: "info.circle") }
                        .accessibilityIdentifier("app-about")
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
        .onAppear { RuntimeBridge.shared.connect(store) }
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

    @ViewBuilder private var nativeFallback: some View {
        switch route {
        case .overview: OverviewView()
        case .services: ServicesView()
        case .devices: DevicesView()
        }
    }
}
