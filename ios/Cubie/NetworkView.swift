import SwiftUI

struct NetworkView: View {
    @EnvironmentObject private var store: BoardStore
    var body: some View {
        Page {
            Card {
                Label("校园网络", systemImage: "wifi").font(.headline)
                InfoRow(title: "连接配置", value: store.network?.profile ?? "尚未获取")
                InfoRow(title: "网卡", value: store.network?.interface ?? "wlan0")
                InfoRow(title: "校园认证", value: store.network?.campusText ?? "尚未获取")
                if let attention = store.network?.requiresAttention {
                    InfoRow(title: "人工处理", value: attention ? "需要检查" : "暂不需要")
                }
                if let attempts = store.network?.attemptsLastHour {
                    InfoRow(title: "近一小时认证提交", value: "\(attempts) 次")
                }
                if let checked = store.network?.campusCheckedAt {
                    InfoRow(title: "认证检测时间", value: Display.date(checked)?.formatted(date: .omitted, time: .standard) ?? "未知")
                }
            }
            Card {
                Label("远程链路", systemImage: "network").font(.headline)
                InfoRow(title: "Cloudflare Tunnel", value: store.network.map { $0.tunnelReady ? "已就绪" : "未就绪" } ?? "尚未获取")
                InfoRow(title: "管理 API", value: store.demo ? "演示" : store.stale ? "未确认连通" : "可达")
                Text("校园网认证成功不等于隧道就绪；API 可达也不等于所有服务健康。这里分别检测。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card {
                Label("连接保护", systemImage: "lock.shield").font(.headline)
                Text("继续使用现有认证冷却、验证码暂停和重试预算。本 App 不会清空记录、反复提交密码，或自动切换到其他 Wi-Fi。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("设备完全离线时，App 无法代替它完成网页验证码；此处会保留最后状态并标记过期。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("网络")
    }
}
