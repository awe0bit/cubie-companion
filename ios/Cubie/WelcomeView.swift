import SwiftUI

struct WelcomeView: View {
    let connect: () -> Void
    let explore: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Spacer(minLength: 32)
                Image("CoreNestMark").resizable().scaledToFit().frame(width: 104, height: 96)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("栖核 CoreNest").font(.largeTitle.weight(.semibold)).accessibilityIdentifier("welcome-title")
                    Text(Brand.tagline).font(.title3).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 24) {
                    feature("看见设备的状态", detail: "温度、资源和服务，一眼掌握。", symbol: "waveform.path.ecg")
                    feature("分清每一层连接", detail: "校园网、隧道和服务，各自呈现。", symbol: "network")
                    feature("扫码即可绑定", detail: "核对配对码，凭据留在本机。", symbol: "qrcode.viewfinder")
                }
                VStack(spacing: 12) {
                    Button(action: connect) {
                        Text("连接我的开发板").font(.headline).foregroundStyle(Brand.onAccent)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("welcome-connect")
                        .buttonBorderShape(.roundedRectangle(radius: Layout.cardRadius))
                    Button("先看看演示", action: explore).controlSize(.large).accessibilityIdentifier("welcome-demo")
                    Text("演示使用示例数据，不会连接或操作真实设备。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, typeSize.isAccessibilitySize ? 24 : 32)
            .padding(.bottom, 28)
            .frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Surface.canvas)
    }

    private func feature(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Brand.accent).frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
