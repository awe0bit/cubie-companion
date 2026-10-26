import SwiftUI

struct AboutView: View {
    @StateObject private var updates = AppUpdateChecker()
    @ObservedObject private var runtime = RuntimeBridge.shared
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    BrandLockup(size: 64)
                    Text(Brand.tagline).foregroundStyle(.secondary)
                    Text("开发板服务的原生控制台。当前版本面向 Radxa Cubie A7S，服务端默认只读。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Section("版本与兼容") {
                LabeledContent("版本", value: "\(Brand.version) (\(Brand.build))")
                LabeledContent("最低系统", value: "iOS 17")
                LabeledContent("液态玻璃导航", value: "iOS 26 及更新版本")
                Text("旧系统使用原生标签栏；透明度与动态效果遵从系统辅助功能设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("页面热更新") {
                LabeledContent("运行时", value: runtime.runtime)
                LabeledContent("通道", value: runtime.channel == "not-configured" ? "未配置" : runtime.channel)
                Text(updateMessage).font(.subheadline).accessibilityIdentifier("ota-status")
                if runtime.updateStage != "disabled" && runtime.channel != "not-configured" {
                    Button("检查页面更新") { runtime.checkUpdate() }
                        .disabled(["checking", "downloading"].contains(runtime.updateStage))
                        .accessibilityIdentifier("ota-check")
                }
                Text("页面、样式和资源可热更新；新权限、原生依赖或桥接变更仍需新版 IPA。下载后下次冷启动生效，不强制重载当前页面。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("安装包更新") {
                packageUpdate
                Button("检查新版安装包") { Task { await updates.check(force: true) } }
                    .disabled(updates.state == .checking).accessibilityIdentifier("release-check")
                Text("未签 IPA 仍需使用自己的有效签名安装，热更新不能续签或绕过 iOS 安装限制。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("隐私与安全") {
                Label("没有广告和第三方统计 SDK", systemImage: "hand.raised")
                Label("设备和 Access 凭据仅存本机钥匙串", systemImage: "key")
                Label("仅在前台刷新；不会在后台反复认证", systemImage: "pause.circle")
                Text("连接请求经过你配置的 Cloudflare 服务。删除本机连接不会撤销服务器凭据；手机丢失后仍应在服务端撤销。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("项目") {
                Link(destination: URL(string: "https://github.com/awe0bit/cubie-companion")!) {
                    Label("源码与版本记录", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Text("当前仍为开发预览，不把编译通过等同于生产环境、真机联网或长期稳定性已验收。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("关于栖核").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(Surface.canvas)
            .task { if !LaunchMode.isUITesting { await updates.check() } }
    }

    private var updateMessage: String {
        switch runtime.updateStage {
        case "disabled": return "尚未启用远程 OTA，当前使用随安装包内置的界面。"
        case "checking": return "正在检查页面更新…"
        case "downloading": return "正在下载页面更新…"
        case "pending": return "已下载，下次冷启动自动应用。"
        case "current": return "当前页面已是最新兼容版本。"
        case "error": return "暂时无法获取更新，继续使用当前可用界面。"
        default: return runtime.channel == "not-configured" ? "尚未配置独立 OTA 项目，当前使用内置界面。" : "等待检查页面更新。"
        }
    }

    @ViewBuilder private var packageUpdate: some View {
        switch updates.state {
        case .idle: Text("尚未检查安装包版本。")
        case .checking: ProgressView("正在检查…")
        case .current: Label("当前安装包已是最新版本", systemImage: "checkmark.circle")
        case .unpublished: Text("还没有可下载的正式 iOS 发布包。")
        case .failed: Text("无法获取版本信息，请稍后重试。")
        case .available(let release):
            Text("发现 \(release.version)").font(.headline)
            if let body = release.body, !body.isEmpty { Text(String(body.prefix(2000))).font(.subheadline) }
            if let ipa = release.ipa { Link("下载未签 IPA", destination: ipa) }
            Link("发布说明与 SHA256 校验", destination: release.html_url)
        }
    }
}
