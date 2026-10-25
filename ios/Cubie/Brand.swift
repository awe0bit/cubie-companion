import SwiftUI

#if DEBUG
private let previewLaunchEnabled = true
#else
private let previewLaunchEnabled = false
#endif

enum Brand {
    static let name = "CoreNest"
    static let chineseName = "栖核"
    static let tagline = "让设备与服务，各归其位。"
    static let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.3.0"
    static let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "3"
    static let accent = Color("AccentColor")
}

enum AppTab: String, CaseIterable {
    case overview, services, network, settings
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published var selection: AppTab = .overview
}

enum LaunchMode {
    static let isUITesting = previewLaunchEnabled && ProcessInfo.processInfo.arguments.contains("--ui-testing")

    static func argument(after name: String) -> String? {
        guard isUITesting, let index = ProcessInfo.processInfo.arguments.firstIndex(of: name),
              index + 1 < ProcessInfo.processInfo.arguments.count else { return nil }
        return ProcessInfo.processInfo.arguments[index + 1]
    }

    static var appearance: ColorScheme? {
        switch argument(after: "--preview-appearance") {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}

struct BrandLockup: View {
    var size: CGFloat = 48
    var body: some View {
        HStack(spacing: 12) {
            Image("CoreNestMark").resizable().scaledToFit().frame(width: size, height: size)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(Brand.name).font(.title3.weight(.semibold))
                Text(Brand.chineseName).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}
