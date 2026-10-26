import SwiftUI

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
                }.tabBarMinimizeBehavior(.never)
            } else {
                TabView(selection: $navigation.selection) {
                    NavigationStack { RuntimeScreen(route: .overview) }
                        .tabItem { Label("概览", systemImage: "square.grid.2x2") }.tag(AppTab.overview)
                    NavigationStack { RuntimeScreen(route: .services) }
                        .tabItem { Label("服务", systemImage: "square.stack.3d.up") }.tag(AppTab.services)
                    DeviceNavigationView()
                        .tabItem { Label("设备", systemImage: "cpu") }.tag(AppTab.devices)
                }
            }
        }
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
            } else {
                showWelcome = !hasSeenWelcome && store.demo
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active, !LaunchMode.isUITesting else { return }
            while !Task.isCancelled {
                await store.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { break }
            }
        }
    }
}
