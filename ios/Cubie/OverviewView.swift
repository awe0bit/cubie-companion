import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: BoardStore
    @EnvironmentObject private var navigation: AppNavigation
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var temperatureSize = 48.0
    private var board: BoardStatus? { store.status }
    private var hottest: Temperature? { board?.temperatures.max { $0.celsius < $1.celsius } }

    var body: some View {
        Page {
            if store.demo {
                Button { navigation.selection = .settings } label: {
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder").font(.title2).foregroundStyle(Brand.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("绑定开发板").font(.headline)
                                Text("扫码后查看真实状态").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("overview-connect")
            }
            if let board {
                Card {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(board.hostname).font(.headline)
                            Text("Cubie A7S").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "cpu").font(.title2).foregroundStyle(Brand.accent).accessibilityHidden(true)
                    }
                    if let hottest {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", hottest.celsius))
                                .font(.system(size: temperatureSize, weight: .medium)).monospacedDigit()
                                .minimumScaleFactor(0.5).lineLimit(1)
                            Text("°C").font(.title3).foregroundStyle(.secondary)
                            Spacer()
                            Text("最高温度").font(.caption).foregroundStyle(.secondary)
                        }
                        if hottest.celsius >= 75 {
                            Label("温度偏高，请检查散热", systemImage: "thermometer.sun")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if let uptime = board.uptimeSeconds {
                        Text("已运行 \(Display.uptime(uptime))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: Layout.spacing) {
                    if let cpu = board.cpuPercent {
                        Metric(title: "CPU", value: String(format: "%.1f%%", cpu), symbol: "cpu", detail: "实时利用率")
                    }
                    if let used = board.memoryUsedBytes {
                        Metric(title: "内存", value: Display.bytes(used), symbol: "memorychip",
                               detail: board.memoryTotalBytes.map { "共 \(Display.bytes($0))" } ?? "")
                    }
                    if let used = board.diskUsedBytes {
                        Metric(title: "存储", value: Display.bytes(used), symbol: "internaldrive",
                               detail: board.diskTotalBytes.map { "共 \(Display.bytes($0))" } ?? "")
                    }
                    if let rx = board.rxBytesPerSecond {
                        Metric(title: "下载", value: Display.bytes(rx) + "/s", symbol: "arrow.down",
                               detail: board.txBytesPerSecond.map { "上传 \(Display.bytes($0))/s" } ?? "")
                    }
                    if let power = board.powerWatts {
                        Metric(title: "功耗", value: String(format: "%.1f W", power), symbol: "bolt")
                    }
                    if let rpm = board.fanRPM {
                        Metric(title: "风扇", value: "\(Int(rpm)) RPM", symbol: "fan")
                    }
                }
            } else {
                ContentUnavailableView("等待设备数据", systemImage: "cpu", description: Text("连接成功后自动更新，也可下拉刷新。"))
            }
            NavigationLink { NetworkView() } label: {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "wifi").font(.title2).foregroundStyle(Brand.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("网络连接").font(.headline)
                            Text(store.network?.campusText ?? "等待数据").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }.buttonStyle(.plain).accessibilityIdentifier("network-details")
        }.navigationTitle(Brand.chineseName)
    }
}
