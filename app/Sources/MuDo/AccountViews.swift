import AppKit
import MuDoCore
import SwiftUI

/// The Accounts tab: cswap accounts with 5h / 7d usage; a click switches the active one.
struct AccountListView: View {
    let cswap: CswapModel

    /// Room left for the list: most of the main screen's height, minus the tab bar, footer and margins.
    static var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen * 0.7 - 120)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // cswap keeps accounts per machine: one machine at a time, never mixed in one list.
            if cswap.sources.count > 1 {
                Picker("", selection: Bindable(cswap).selectedSource) {
                    ForEach(cswap.sources) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            if let source = cswap.current {
                Text("Switching here changes cswap on \(source.name)")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6)
                // The widget is not taller than the screen: the list scrolls.
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        if source.accounts.isEmpty && source.error == nil {
                            Text("No accounts").font(.caption).foregroundStyle(.secondary).padding(6)
                        }
                        ForEach(source.accounts) { account in
                            AccountRowView(account: account, busy: cswap.switching != nil,
                                           switchingHere: cswap.isSwitching(source, account)) {
                                Task { await cswap.switchTo(account, in: source) }
                            }
                        }
                        if let error = source.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                                .lineLimit(2).padding(.horizontal, 6).padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: Self.maxListHeight)
            } else {
                Text(cswap.loading ? "Loading…" : "No accounts")
                    .font(.caption).foregroundStyle(.secondary).padding(6)
            }
            Text("A switch applies to new Claude Code sessions.")
                .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 6)
        }
        // Refreshes on open and every minute while the tab is on screen.
        .task {
            while !Task.isCancelled {
                await cswap.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
}

struct AccountRowView: View {
    let account: CswapAccount
    let busy: Bool
    let switchingHere: Bool
    let onSwitch: () -> Void

    var body: some View {
        let row = CswapRowModel(account)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if switchingHere {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: row.active ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(row.active ? Color.green : Color.secondary)
                }
                Text(row.title).lineLimit(1).truncationMode(.middle)
                    .fontWeight(row.active ? .semibold : .regular)
                Spacer(minLength: 0)
            }
            if !row.subtitle.isEmpty {
                Text(row.subtitle).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).padding(.leading, 20)
            }
            ForEach(Array(row.windows.prefix(2).enumerated()), id: \.offset) { _, w in
                UsageBar(window: w, showReset: !row.stale)
            }
            if let scoped = scopedText(row) {
                Text(scoped).font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
            }
            if let detail = row.detail {
                Text(detail).font(.caption2).foregroundStyle(.orange).padding(.leading, 20)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if row.switchable && !busy { onSwitch() } }
        .opacity(row.stale ? 0.55 : (busy && !switchingHere ? 0.6 : 1))
        .help(row.switchable ? "Switch to this account" : "")
    }

    private func scopedText(_ row: CswapRowModel) -> String? {
        let extra = row.windows.dropFirst(2)
        guard !extra.isEmpty else { return nil }
        return extra.map { "\($0.name) \(CswapRowModel.percent($0.pct))" }.joined(separator: " · ")
    }
}

struct UsageBar: View {
    let window: CswapWindow
    /// False for stale readings: their reset time has already passed.
    let showReset: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(window.name).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * min(max(window.pct, 0), 100) / 100)
                }
            }
            .frame(height: 5)
            Text(CswapRowModel.percent(window.pct)).font(.caption2.monospacedDigit())
                .frame(width: 32, alignment: .trailing)
            Text(showReset ? (window.countdown.map { "in \($0)" } ?? "") : "").font(.caption2).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading).lineLimit(1)
        }
        .padding(.leading, 20)
    }

    private var color: Color {
        switch CswapSeverity(pct: window.pct) {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}
