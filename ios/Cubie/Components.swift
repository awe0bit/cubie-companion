import SwiftUI

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }
}

struct Page<Content: View>: View {
    @EnvironmentObject private var store: BoardStore
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TimelineView(.periodic(from: .now, by: 5)) { _ in ConnectionBanner() }
                content
            }.padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await store.refresh() }
    }
}

struct ConnectionBanner: View {
    @EnvironmentObject private var store: BoardStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.demo {
                Label("演示模式 · 所有数值均为示例", systemImage: "sparkles")
                    .font(.caption.weight(.medium)).foregroundStyle(.orange)
                    .accessibilityIdentifier("demo-banner")
            } else {
                HStack(spacing: 7) {
                    Circle().fill(store.stale ? .orange : .teal).frame(width: 7, height: 7)
                    Text(store.stale ? "未确认在线 · 数据可能已过期" : "已连接管理 API")
                    Spacer()
                    if store.refreshing { ProgressView().controlSize(.mini) }
                }.font(.caption).foregroundStyle(.secondary)
                if let last = store.lastContact {
                    Text("上次成功刷新 \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }
}

struct Metric: View {
    let title: String
    let value: String
    let symbol: String
    var detail: String = ""
    var body: some View {
        Card {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().minimumScaleFactor(0.7)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.subheadline)
    }
}
