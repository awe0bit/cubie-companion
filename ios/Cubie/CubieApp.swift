import SwiftUI
import UIKit

@main
struct CoreNestApp: App {
    @UIApplicationDelegateAdaptor(RuntimeAppDelegate.self) private var runtimeDelegate
    @StateObject private var store = BoardStore()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store).tint(Brand.accent) }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var navigation = AppNavigation()
    @AppStorage("hasSeenWelcome.v1") private var hasSeenWelcome = false
    @State private var showWelcome = false
    @State private var initialAppearanceHandled = false
    @State private var showDeveloper = false

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                // System-owned Liquid Glass. No material overlay or UIKit bar override.
                TabView(selection: $navigation.selection) {
                    Tab("概览", systemImage: "square.grid.2x2", value: AppTab.overview) {
                        NavigationStack { RuntimeScreen(route: .overview) }
                    }
                    Tab("服务", systemImage: "square.stack.3d.up", value: AppTab.services) {
                        NavigationStack { RuntimeScreen(route: .services) }
                    }
                    Tab("设备", systemImage: "cpu", value: AppTab.devices) {
                        DeviceNavigationView()
                    }
                    Tab("设置", systemImage: "gearshape", value: AppTab.settings) {
                        NavigationStack { AppSettingsView() }
                    }
                }.tabBarMinimizeBehavior(.never)
            } else {
                TabView(selection: $navigation.selection) {
                    NavigationStack { RuntimeScreen(route: .overview) }
                        .tabItem { Label("概览", systemImage: "square.grid.2x2") }.tag(AppTab.overview)
                    NavigationStack { RuntimeScreen(route: .services) }
                        .tabItem { Label("服务", systemImage: "square.stack.3d.up") }.tag(AppTab.services)
                    DeviceNavigationView()
                        .tabItem { Label("设备", systemImage: "cpu") }.tag(AppTab.devices)
                    NavigationStack { AppSettingsView() }
                        .tabItem { Label("设置", systemImage: "gearshape") }.tag(AppTab.settings)
                }
            }
        }
        .background(DeveloperTabGesture {
            guard !showWelcome, !showDeveloper else { return }
            navigation.selection = .settings
            showDeveloper = true
        })
        .environmentObject(navigation)
        .preferredColorScheme(LaunchMode.appearance)
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeView {
                hasSeenWelcome = true
                showWelcome = false
                navigation.selection = .devices
            } explore: {
                hasSeenWelcome = true
                showWelcome = false
                store.showDemo()
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showDeveloper) {
            NavigationStack {
                RuntimeScreen(route: .developer)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { showDeveloper = false } } }
            }
        }
        .onAppear {
            guard !initialAppearanceHandled else { return }
            initialAppearanceHandled = true
            if LaunchMode.isUITesting {
                store.showDemo()
                if let value = LaunchMode.argument(after: "--preview-tab"), let tab = AppTab(rawValue: value) {
                    navigation.selection = tab
                    showWelcome = false
                } else {
                    showWelcome = true
                }
                if LaunchMode.argument(after: "--preview-detail") == "developer" { showDeveloper = true }
            } else {
                showWelcome = !hasSeenWelcome && store.demo
            }
        }
        .task(id: "\(scenePhase)-\(store.endpoint)") {
            guard scenePhase == .active, !LaunchMode.isUITesting else { return }
            await store.receiveLiveUpdates()
        }
    }
}

/// Attaches to the existing system tab bar. It never replaces its delegate, layout or appearance.
private struct DeveloperTabGesture: UIViewControllerRepresentable {
    let reveal: () -> Void
    func makeUIViewController(context: Context) -> Probe { Probe(reveal: reveal) }
    func updateUIViewController(_ controller: Probe, context: Context) { controller.reveal = reveal; controller.install() }
    static func dismantleUIViewController(_ controller: Probe, coordinator: ()) { controller.remove() }

    final class Probe: UIViewController, UIGestureRecognizerDelegate {
        var reveal: () -> Void
        private weak var bar: UITabBar?
        private var press: UILongPressGestureRecognizer?
        init(reveal: @escaping () -> Void) { self.reveal = reveal; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { return nil }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); install() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); install() }
        private func find(_ controller: UIViewController) -> UITabBar? {
            if let controller = controller as? UITabBarController,
               controller.tabBar.items?.contains(where: { $0.title == "设置" }) == true { return controller.tabBar }
            for child in controller.children { if let found = find(child) { return found } }
            return nil
        }
        func install() {
            guard let root = view.window?.rootViewController, let found = find(root), found !== bar else { return }
            remove()
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            gesture.minimumPressDuration = 0.65
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            found.addGestureRecognizer(gesture)
            press = gesture; bar = found
        }
        func remove() {
            if let press { bar?.removeGestureRecognizer(press) }
            press = nil; bar = nil
        }
        private func isSettings(_ point: CGPoint, in bar: UITabBar) -> Bool {
            guard let items = bar.items, let index = items.firstIndex(where: { $0.title == "设置" }), !items.isEmpty else { return false }
            // Public UIControl geometry works through the iOS 26 content wrapper too.
            func controls(_ view: UIView) -> [UIControl] {
                view.subviews.flatMap { child -> [UIControl] in
                    if let control = child as? UIControl, !control.isHidden, control.alpha > 0.01 { return [control] }
                    return controls(child)
                }
            }
            let buttons = controls(bar).filter { $0.bounds.width >= 30 && $0.bounds.height >= 25 }
                .sorted { $0.convert($0.bounds, to: bar).minX < $1.convert($1.bounds, to: bar).minX }
            let rtl = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let visual = rtl ? items.count - 1 - index : index
            if buttons.count == items.count { return buttons[visual].convert(buttons[visual].bounds, to: bar).contains(point) }
            // Fallback is confined to the settings slot, not the entire screen/tab bar.
            guard bar.bounds.contains(point), bar.bounds.width > 0 else { return false }
            return min(items.count - 1, Int(point.x / (bar.bounds.width / CGFloat(items.count)))) == visual
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let bar else { return false }
            return isSettings(touch.location(in: bar), in: bar)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let bar, isSettings(gesture.location(in: bar), in: bar) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            reveal()
        }
    }
}
