import SwiftUI

struct AboutView: View {
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
            Section("隐私与安全") {
                Label("没有广告和第三方统计 SDK", systemImage: "hand.raised")
                Label("设备和 Access 凭据仅存本机钥匙串", systemImage: "key")
                Label("仅在前台刷新；不会在后台反复认证", systemImage: "pause.circle")
                Text("连接请求经过你配置的 Cloudflare 服务。删除本机连接不会撤销服务器凭据；手机丢失后仍应在服务端撤销。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("项目") {
                Label("源码与更新请查看部署时使用的项目仓库。", systemImage: "chevron.left.forwardslash.chevron.right")
                Text("当前仍为开发预览，不把编译通过等同于生产环境、真机联网或长期稳定性已验收。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("关于栖核").navigationBarTitleDisplayMode(.inline)
    }
}
