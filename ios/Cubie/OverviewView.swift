import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var temperatureSize = 64.0
    private var board: BoardStatus? { store.status }
    private var hottest: Temperature? { board?.temperatures.max { $0.celsius < $1.celsius } }

    var body: some View {
        Page {
            HStack {
                BrandLockup(size: 40)
                Spacer()
                Text(store.demo ? "演示设备" : "我的设备")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if store.demo {
                Button {
                    navigation.selection = .settings
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                        VStack(alignment: .leading, spacing: 3) {
                            Text("连接你的开发板").font(.subheadline.weight(.semibold))
                            Text("输入设备地址，开始查看真实状态").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }.padding(16)
                }
                .buttonStyle(.plain)
                .background(Brand.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("overview-connect")
            }
            Card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("RADXA / CUBIE A7S").font(.caption.weight(.semibold)).tracking(1.8).foregroundStyle(.secondary)
                        Text("我的开发板").font(.title2.weight(.semibold))
                        Text(board?.hostname ?? "等待连接").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "cpu").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(Brand.accent)
                        .accessibilityHidden(true)
                }
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(hottest.map { String(format: "%.1f", $0.celsius) } ?? "—")
                        .font(.system(size: temperatureSize, weight: .light, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text("°C").font(.title2).foregroundStyle(.secondary)
                    Spacer()
                }
                Text("最高传感器 · \(hottest?.name ?? "尚未提供")")
                    .font(.caption).foregroundStyle(.secondary)
                if let hottest, hottest.celsius >= 75 {
                    Label("温度偏高，请检查散热和当前负载", systemImage: "thermometer.sun")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("已运行 \(Display.uptime(board?.uptimeSeconds))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                Metric(title: "CPU", value: board?.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                       symbol: "cpu", detail: board?.cpuPercent == nil ? "等待第二次采样" : "实时利用率")
                Metric(title: "内存", value: Display.bytes(board?.memoryUsedBytes), symbol: "memorychip",
                       detail: "共 \(Display.bytes(board?.memoryTotalBytes))")
                Metric(title: "存储已用", value: Display.bytes(board?.diskUsedBytes), symbol: "internaldrive",
                       detail: "共 \(Display.bytes(board?.diskTotalBytes))")
                Metric(title: "下载", value: Display.bytes(board?.rxBytesPerSecond) + "/s", symbol: "arrow.down",
                       detail: "wlan0 接收速率")
            }
            Card {
                Text("设备能力").font(.headline)
                InfoRow(title: "整机功耗", value: board?.powerWatts.map { String(format: "%.1f W", $0) } ?? "未提供实测数据")
                InfoRow(title: "风扇转速", value: board?.fanRPM.map { "\(Int($0)) RPM" } ?? "不支持转速反馈")
                Text("不以估算值代替实测。历史曲线和通知将在后续接入。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(Brand.chineseName)
    }
}
