import SwiftUI
import AVFoundation
import VisionKit

struct PairingView: View {
    @EnvironmentObject private var store: BoardStore
    @Environment(\.dismiss) private var dismiss
    @State private var cameraReady = false
    @State private var cameraDenied = false
    @State private var offer: PairingOffer?
    @State private var error: String?
    @State private var verificationCode: String?
    @State private var running = false
    @State private var finished = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if finished {
                    ContentUnavailableView {
                        Label("已安全绑定", systemImage: "checkmark.shield.fill")
                    } description: { Text("凭据已保存到这台 iPhone 的钥匙串。") } actions: {
                        Button("查看设备") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                } else if let offer {
                    Form {
                        Section {
                            Label("确认你要连接的设备", systemImage: "checkmark.shield")
                            Text(offer.endpoint).font(.headline).textSelection(.enabled)
                            Text("二维码不能证明服务器属于谁。请核对域名，只绑定你自己部署的栖核。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let verificationCode {
                            Section("与电脑配对页核对") {
                                Text(verificationCode).font(.system(size: 38, weight: .semibold, design: .monospaced))
                                    .tracking(7).frame(maxWidth: .infinity).padding(.vertical)
                                Text("确认双方验证码一致，然后在电脑网页点击「批准绑定」。")
                                ProgressView("等待浏览器批准…")
                            }
                        } else if !running && error == nil {
                            Section {
                                Button("信任此地址，开始绑定") { start(offer) }
                                    .accessibilityIdentifier("pair-confirm-endpoint")
                            }
                        }
                        if running && verificationCode == nil { ProgressView("正在请求配对…") }
                        if let error { Section { Text(error).foregroundStyle(.orange) } }
                        if !running { Section { Button("重新扫描") { self.offer = nil; error = nil } } }
                    }
                } else if cameraReady {
                    QRScanner { text in
                        guard self.offer == nil else { return }
                        do { self.offer = try PairingOffer.parse(text); error = nil }
                        catch { self.error = error.localizedDescription }
                    } failure: { error = $0; cameraReady = false }
                    .overlay(alignment: .bottom) {
                        Text(error ?? "扫描电脑配对页上的栖核二维码")
                            .font(.callout).padding().background(.regularMaterial, in: Capsule())
                            .padding()
                    }
                } else {
                    ContentUnavailableView {
                        Label(cameraDenied ? "需要相机权限" : "扫码暂不可用", systemImage: "qrcode.viewfinder")
                    } description: {
                        Text(error ?? "请使用支持实时扫码的 iPhone，在设置中允许栖核使用相机。模拟器无法使用摄像头扫码。")
                    } actions: {
                        if cameraDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("打开系统设置", destination: url)
                        }
                    }
                }
            }
            .navigationTitle("扫码绑定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .task { await prepareCamera() }
            .onDisappear { operation?.cancel() }
        }
    }

    @MainActor private func prepareCamera() async {
        guard !LaunchMode.isUITesting, DataScannerViewController.isSupported else { return }
        let permitted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: permitted = true
        case .notDetermined: permitted = await AVCaptureDevice.requestAccess(for: .video)
        default: permitted = false
        }
        cameraDenied = !permitted
        cameraReady = permitted && DataScannerViewController.isAvailable
    }

    @MainActor private func start(_ offer: PairingOffer) {
        guard !running, !LaunchMode.isUITesting else { return }
        running = true; error = nil
        operation = Task { @MainActor in
            defer { running = false }
            do {
                let client = try PairingClient(offer: offer)
                let result = try await client.begin(name: UIDevice.current.model)
                verificationCode = result.verificationCode
                while Date().timeIntervalSince1970 < offer.expiresAt {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let state = try await client.result()
                    if state.state == "approved" {
                        try Task.checkCancellation()
                        try await store.connect(ConnectionCredentials(baseURL: offer.endpoint, apiToken: client.token,
                            accessClientID: "", accessClientSecret: ""))
                        finished = true
                        return
                    }
                    guard state.state == "pending" else {
                        throw ConnectionError.rejected("配对已拒绝、撤销或过期。请在电脑上生成新二维码。")
                    }
                }
                throw ConnectionError.rejected("配对已过期。请重新生成二维码。")
            } catch is CancellationError {
                // Closing the view must never leave a background registration loop running.
            } catch {
                self.error = "绑定未完成。\(error.localizedDescription) 如网页已批准但手机未保存，请在主板撤销该凭据后重新配对。"
                verificationCode = nil
            }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void
    let failure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found, failure: failure) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() }
        catch { DispatchQueue.main.async { failure("相机无法启动，请关闭其他占用相机的应用后重试。") } }
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        let failure: (String) -> Void
        init(found: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
            self.found = found; self.failure = failure
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                if let text = barcode.payloadStringValue { found(text); return }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            failure("相机当前不可用。请稍后重新打开扫码。")
        }
    }
}
