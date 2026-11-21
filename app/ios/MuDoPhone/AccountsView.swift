import MuDoCore
import SwiftUI
import WidgetKit

struct AccountsView: View {
    @Bindable var cswap: PhoneCswap
    @State private var confirming: Pending?
    @State private var usableFirst = ServerStore.sortUsableFirst

    private struct Pending: Identifiable {
        let source: CswapSource
        let account: CswapAccount
        var id: String { "\(source.id)/\(account.number)" }
    }

    var body: some View {
        NavigationStack {
            List {
                if cswap.sources.count > 1 {
                    Picker("Server", selection: $cswap.selectedID) {
                        ForEach(cswap.sources) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                }
                if let source = cswap.current {
                    Text("Switching here changes cswap on \(source.name)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = source.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                    ForEach(CswapOrder.sorted(source.accounts, usableFirst: usableFirst)) { account in
                        AccountRow(account: account, busy: cswap.switching == "\(source.id)/\(account.number)")
                            .contentShape(Rectangle())
                            .accessibilityAddTraits(.isButton)
                            .onTapGesture {
                                if CswapRowModel(account).switchable, cswap.switching == nil { confirming = Pending(source: source, account: account) }
                            }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Usable accounts first", isOn: $usableFirst)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .onChange(of: usableFirst) { _, value in
                ServerStore.sortUsableFirst = value
                WidgetCenter.shared.reloadAllTimelines()
            }
            .refreshable { await cswap.refresh() }
            .task {
                while !Task.isCancelled {
                    await cswap.refresh()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .alert("Switch account?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                   presenting: confirming) { pending in
                Button("Switch") { Task { await cswap.switchTo(pending.account, in: pending.source) } }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text("Use \(CswapRowModel(pending.account).title) on \(pending.source.name). New Claude Code sessions use it; running ones keep their account.")
            }
        }
    }
}

private struct AccountRow: View {
    let account: CswapAccount
    let busy: Bool

    var body: some View {
        let row = CswapRowModel(account)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(row.active ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.headline).lineLimit(1)
                if !row.subtitle.isEmpty { Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let detail = row.detail { Text(detail).font(.caption).foregroundStyle(.orange) }
                ForEach(row.windows.prefix(2), id: \.name) { w in
                    HStack(spacing: 6) {
                        Text(w.name).font(.caption2).frame(width: 24, alignment: .leading)
                        ProgressView(value: min(max(w.pct, 0), 100) / 100).tint(Self.tint(w.pct))
                        Text(CswapRowModel.percent(w.pct)).font(.caption2).frame(width: 36, alignment: .trailing)
                        if let c = w.countdown { Text(c).font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                let scoped = row.windows.dropFirst(2).map { "\($0.name) \(CswapRowModel.percent($0.pct))" }
                if !scoped.isEmpty { Text(scoped.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if busy { ProgressView() }
        }
        .opacity(row.stale || !row.switchable && !row.active ? 0.55 : 1)
    }

    private static func tint(_ pct: Double) -> Color {
        switch CswapSeverity(pct: pct) {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }
}
