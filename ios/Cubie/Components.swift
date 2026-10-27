import SwiftUI

struct OperationFeedback: View {
    @EnvironmentObject private var store: BoardStore
    let kind: String
    let target: String

    var body: some View {
        if let operation = store.operation, operation.kind == kind, operation.target == target {
            HStack(alignment: .top, spacing: 8) {
                if operation.busy { ProgressView().controlSize(.small) }
                else {
                    Image(systemName: operation.phase == .confirmed ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(operation.phase == .confirmed ? Color.green : Color.orange)
                }
                Text(operation.message).font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("control-feedback")
            .accessibilityLabel(operation.message)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Layout.spacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.cardInset)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous))
    }
}

struct Page<Content: View>: View {
    @EnvironmentObject private var store: BoardStore
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Layout.spacing) {
                TimelineView(.periodic(from: .now, by: 5)) { _ in ConnectionBanner() }
                content
            }.frame(maxWidth: 640).frame(maxWidth: .infinity).padding(Layout.pageInset)
        }
        .background(Surface.canvas)
        .refreshable { await store.refresh(manual: true) }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConnectionBanner: View {
    @EnvironmentObject private var store: BoardStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.demo {
                Label("演示数据", systemImage: "sparkles")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("demo-banner")
            } else {
                HStack(spacing: 7) {
                    Circle().fill(store.stale ? .orange : .teal).frame(width: 7, height: 7)
                    Text(store.stale ? "连接中断 · 上次数据" : "已连接")
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary)
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
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }.accessibilityElement(children: .combine)
    }
}

struct InfoRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let value: String
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).foregroundStyle(.secondary)
                    Text(value).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    Text(title).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
        }.font(.subheadline)
    }
}
