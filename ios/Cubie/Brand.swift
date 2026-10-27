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
    static let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.8.0"
    static let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "10"
    static let accent = Color("AccentColor")
    // Blue filled controls use dark text in BOTH appearances for readable contrast.
    static let onAccent = Color(red: 0.07, green: 0.09, blue: 0.12)
}

enum AppTab: String, CaseIterable {
    case overview, services, devices, settings
}

enum Layout {
    static let pageInset: CGFloat = 16
    static let cardInset: CGFloat = 14
    static let cardRadius: CGFloat = 16
    static let spacing: CGFloat = 10
}

enum Surface {
    static let canvas = adaptive(0xF3F4F5, 0x0B0B0B)
    static let card = adaptive(0xFFFFFF, 0x171717)
    static let ink = adaptive(0x1A1C1F, 0xF5F5F5)
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
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
