import SwiftUI

@main
struct CoreNestApp: App {
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
                        NavigationStack { OverviewView() }
                    }
                    Tab("服务", systemImage: "square.stack.3d.up", value: AppTab.services) {
                        NavigationStack { ServicesView() }
                    }
                    Tab("绑定", systemImage: "qrcode.viewfinder", value: AppTab.settings) {
                        NavigationStack { SettingsView() }
                    }
                }.tabBarMinimizeBehavior(.never)
            } else {
                TabView(selection: $navigation.selection) {
                    NavigationStack { OverviewView() }
                        .tabItem { Label("概览", systemImage: "square.grid.2x2") }.tag(AppTab.overview)
                    NavigationStack { ServicesView() }
                        .tabItem { Label("服务", systemImage: "square.stack.3d.up") }.tag(AppTab.services)
                    NavigationStack { SettingsView() }
                        .tabItem { Label("绑定", systemImage: "qrcode.viewfinder") }.tag(AppTab.settings)
                }
            }
        }
        .environmentObject(navigation)
        .preferredColorScheme(LaunchMode.appearance)
        .fullScreenCover(isPresented: $showWelcome) {
            WelcomeView {
                hasSeenWelcome = true
                showWelcome = false
                navigation.selection = .settings
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
