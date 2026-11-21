import MuDoCore
import SwiftUI
import WidgetKit

struct MuDoWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MuDoEntry

    var body: some View {
        content
            .containerBackground(.fill.tertiary, for: .widget)
            .widgetURL(URL(string: entry.content == .sessions && family == .accessoryRectangular
                           ? "mudo://open?tab=sessions" : "mudo://open?tab=accounts"))
    }

    @ViewBuilder private var content: some View {
        if let message = entry.message {
            Text(message).font(.footnote)
        } else {
            switch family {
            case .systemSmall:
                VStack(alignment: .leading, spacing: 4) { AccountBlock(entry: entry); Spacer(minLength: 0); Fetched(date: entry.date) }
            case .systemMedium:
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) { AccountBlock(entry: entry); Spacer(minLength: 0); Fetched(date: entry.date) }
                    Divider()
                    SessionList(entry: entry, compact: false)
                }
            case .systemLarge:
                VStack(alignment: .leading, spacing: 6) {
                    AccountList(entry: entry)
                    Divider()
                    SessionList(entry: entry, compact: false)
                    Spacer(minLength: 0)
                    Fetched(date: entry.date)
                }
            case .accessoryRectangular:
                if entry.content == .sessions { SessionList(entry: entry, compact: true) } else { AccountBlock(entry: entry) }
            case .accessoryCircular:
                if let w = entry.active?.windows.first(where: { $0.name == "5h" }) {
                    Gauge(value: min(max(w.pct, 0), 100) / 100) { Text("5h") } currentValueLabel: { Text(CswapRowModel.percent(w.pct)) }
                        .gaugeStyle(.accessoryCircular)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                }
            case .accessoryInline:
                Text(inlineText)
            default:
                AccountBlock(entry: entry)
            }
        }
    }

    private var inlineText: String {
        guard let a = entry.active else { return entry.accountsError ?? "no active account" }
        let row = CswapRowModel(a)
        let parts = a.windows.prefix(2).map { "\($0.name) \(CswapRowModel.percent($0.pct))" }
        return ([row.title.components(separatedBy: "@").first ?? row.title] + parts).joined(separator: " ")
    }
}

private struct Fetched: View {
    let date: Date
    var body: some View {
        Text("\(Text(date, style: .relative)) ago").font(.caption2).foregroundStyle(.secondary)
    }
}

private func tint(_ pct: Double) -> Color {
    switch CswapSeverity(pct: pct) {
    case .low: .green
    case .medium: .orange
    case .high: .red
    }
}

private struct UsageBar: View {
    let window: CswapWindow
    var body: some View {
        HStack(spacing: 4) {
            Text(window.name).font(.caption2).frame(width: 22, alignment: .leading)
            ProgressView(value: min(max(window.pct, 0), 100) / 100).tint(tint(window.pct))
            Text(CswapRowModel.percent(window.pct)).font(.caption2).frame(width: 34, alignment: .trailing)
        }
    }
}

/// The active account of the server: name and the 5 h / 7 d bars, or what is wrong with it.
private struct AccountBlock: View {
    let entry: MuDoEntry

    var body: some View {
        if let account = entry.active {
            let row = CswapRowModel(account)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.headline).lineLimit(1)
                if let detail = row.detail { Text(detail).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
                ForEach(account.windows.prefix(2), id: \.name) { UsageBar(window: $0) }
            }
        } else {
            Text(entry.accountsError ?? "No active account").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct AccountList: View {
    let entry: MuDoEntry

    var body: some View {
        if entry.accounts.isEmpty {
            Text(entry.accountsError ?? "No accounts").font(.footnote).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(entry.accounts.prefix(5)) { account in
                    let row = CswapRowModel(account)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: row.active ? "checkmark.circle.fill" : "circle").font(.caption2)
                                .foregroundStyle(row.active ? Color.green : Color.secondary)
                            Text(row.title).font(.caption).bold().lineLimit(1)
                            if let detail = row.detail { Text(detail).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1) }
                        }
                        ForEach(account.windows.prefix(2), id: \.name) { UsageBar(window: $0) }
                    }
                    .opacity(account.status == .reloginRequired ? 0.55 : 1)
                }
            }
        }
    }
}

private struct SessionList: View {
    let entry: MuDoEntry
    let compact: Bool

    var body: some View {
        if entry.sessions.isEmpty {
            Text(entry.sessionsError ?? "No sessions").font(.footnote).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: compact ? 1 : 4) {
                ForEach(entry.sessions) { s in
                    HStack(spacing: 5) {
                        Circle().fill(color(s.state)).frame(width: 7, height: 7)
                        Text(s.project).font(compact ? .caption : .footnote).bold().lineLimit(1)
                        Spacer(minLength: 2)
                        Text(compact ? s.state.rawValue : ElapsedFormat.short(Date().timeIntervalSince(s.stateSince)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func color(_ state: SessionState) -> Color {
        switch state {
        case .running: .blue
        case .waiting: .orange
        case .done: .green
        case .idle, .ended: .gray
        }
    }
}
