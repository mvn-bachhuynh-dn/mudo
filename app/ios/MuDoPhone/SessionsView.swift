import MuDoCore
import SwiftUI

struct SessionsView: View {
    let model: PhoneModel
    @State private var showAllIdle = false

    var body: some View {
        let store = model.store
        let split = IdleFold.split(store.rows, showAll: showAllIdle)
        let slackTeam = ServerStore.slackTeamID  // one Keychain read per body, not per row
        NavigationStack {
            List {
                if store.rows.isEmpty {
                    Text(model.servers.isEmpty ? "No servers yet. Add one in the Servers tab." : "No sessions.")
                        .foregroundStyle(.secondary)
                }
                ForEach(split.rows) { row in
                    SessionRowView(row: row, showServer: store.hasMultipleServers, slackTeam: slackTeam)
                }
                if split.hidden > 0 {
                    Button("+\(split.hidden) idle") { showAllIdle = true }
                } else if showAllIdle {
                    Button("Fold idle") { showAllIdle = false }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Sessions")
            .task {
                // Keeps elapsed times and stale/idle buckets current while the tab is visible.
                while !Task.isCancelled {
                    store.tick()
                    try? await Task.sleep(for: .seconds(15))
                }
            }
        }
    }
}

private struct SessionRowView: View {
    let row: SessionRow
    let showServer: Bool
    let slackTeam: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = SlackLink.mobileURL(for: row.session, fallbackTeam: slackTeam) {
            Button { openURL(url) } label: {
                HStack(alignment: .top, spacing: 8) {
                    content
                    Image(systemName: "arrow.up.right.square").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the Slack thread")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.session.project).font(.headline).lineLimit(1)
                    Spacer()
                    Text(ElapsedFormat.short(row.elapsed)).font(.caption).foregroundStyle(.secondary)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !row.session.lastPrompt.isEmpty {
                    Text(row.session.lastPrompt).font(.footnote).lineLimit(2)
                }
            }
        }
        .opacity(row.offline ? 0.5 : 1)
    }

    private var subtitle: String {
        var parts = [row.session.state.rawValue, row.session.agent]
        if showServer { parts.append(row.serverName) }
        return parts.joined(separator: " · ")
    }

    private var color: Color {
        switch row.session.state {
        case .running: .blue
        case .waiting: .orange
        case .done: .green
        case .idle, .ended: .gray
        }
    }
}
