import SwiftUI

struct NetworkView: View {
    @EnvironmentObject private var store: BoardStore
    var body: some View {
        Page {
            if let network = store.network {
                Card {
                    Label("校园网络", systemImage: "wifi").font(.headline)
                    if let profile = network.profile { InfoRow(title: "网络", value: profile) }
                    InfoRow(title: "网卡", value: network.interface)
                    InfoRow(title: "认证", value: network.campusText)
                    if network.requiresAttention == true {
                        Label("需要在设备端处理认证", systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                    if let attempts = network.attemptsLastHour {
                        InfoRow(title: "近一小时认证", value: "\(attempts) 次")
                    }
                    if let checked = network.campusCheckedAt, let date = Display.date(checked) {
                        InfoRow(title: "检测时间", value: date.formatted(date: .omitted, time: .standard))
                    }
                }
                Card {
                    Label("远程连接", systemImage: "network").font(.headline)
                    InfoRow(title: "隧道", value: network.tunnelReady ? "已就绪" : "未就绪")
                    InfoRow(title: "管理 API", value: store.demo ? "演示" : store.stale ? "未确认连通" : "可达")
                }
            } else {
                ContentUnavailableView("暂无网络数据", systemImage: "wifi.slash", description: Text("请检查设备连接后下拉刷新。"))
            }
        }.navigationTitle("网络")
    }
}
