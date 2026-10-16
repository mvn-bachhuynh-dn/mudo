import MuDoCore
import SwiftUI

struct RootView: View {
    let model: AppModel
    let panel: PanelState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PillView(summary: model.store.pill, hasServers: !model.settings.servers.isEmpty)
                .contentShape(Rectangle())
                .onTapGesture { panel.togglePinned() }
            if panel.isExpanded {
                SessionListView(model: model)
            }
        }
        .padding(8)
        .frame(width: panel.isExpanded ? 320 : nil, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .fixedSize()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { panel.contentSizeChanged($0) }
    }
}

struct PillView: View {
    let summary: PillSummary
    let hasServers: Bool

    var body: some View {
        HStack(spacing: 10) {
            if !hasServers {
                Label("Add a server", systemImage: "plus.circle").foregroundStyle(.secondary)
            } else if summary.offline {
                Label("offline", systemImage: "wifi.slash").foregroundStyle(.secondary)
            } else {
                count("circle.fill", summary.running, .blue)
                count("hourglass.circle.fill", summary.waiting, .orange)
                count("checkmark.circle.fill", summary.done, .green)
            }
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .blink(summary.blinking)
    }

    private func count(_ symbol: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(n)")
        }
        .opacity(n == 0 ? 0.4 : 1)
    }
}

struct SessionListView: View {
    let model: AppModel

    var body: some View {
        let store = model.store
        let rows = store.rows
        VStack(alignment: .leading, spacing: 2) {
            if rows.isEmpty && store.problemServers.isEmpty {
                Text("No sessions").font(.caption).foregroundStyle(.secondary).padding(6)
            }
            ForEach(rows) { row in
                SessionRowView(row: row, showHost: store.hasMultipleServers,
                               onOpen: { model.open(row) }, onSnooze: { model.snooze(row) })
            }
            ForEach(store.problemServers) { server in
                ServerStatusRow(server: server)
            }
        }
    }
}

struct SessionRowView: View {
    let row: SessionRow
    let showHost: Bool
    let onOpen: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StateIcon(bucket: row.bucket).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.session.project).fontWeight(.semibold).lineLimit(1)
                    Text(row.session.agent).foregroundStyle(.secondary)
                    if showHost {
                        Text(row.serverName).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                    if row.offline {
                        Text("?").foregroundStyle(.secondary)
                    }
                    Text(row.bucket == .idle ? "idle" : ElapsedFormat.short(row.elapsed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if row.blinking {
                        Button(action: onSnooze) {
                            Image(systemName: "pause.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Snooze")
                    }
                }
                if !row.session.lastPrompt.isEmpty {
                    Text(row.session.lastPrompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        // Pointing at a blinking row counts as "seen" (snooze). Continuous hover also catches a row
        // that starts blinking under a resting pointer as soon as the pointer moves.
        .onContinuousHover { phase in
            if case .active = phase, row.blinking { onSnooze() }
        }
        .opacity(row.offline ? 0.5 : 1)
        .blink(row.blinking)
    }
}

struct ServerStatusRow: View {
    let server: ServerRow

    var body: some View {
        HStack(spacing: 6) {
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            Text("\(server.name) \(label)").font(.caption).foregroundStyle(.secondary).fixedSize()
            Rectangle().frame(height: 1).foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var label: String {
        switch server.status {
        case .connecting: "connecting…"
        case .unauthorized: "token invalid"
        case .offline, .connected: "offline"
        }
    }
}

struct StateIcon: View {
    let bucket: Bucket

    var body: some View {
        switch bucket {
        case .waiting:
            Image(systemName: "hourglass.circle.fill").foregroundStyle(.orange)
        case .stale:
            Image(systemName: "sparkle").foregroundStyle(.green)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .running:
            Image(systemName: "circle.fill").foregroundStyle(.blue).symbolEffect(.pulse)
        case .idle:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }
}

/// 1 Hz opacity pulse; a steady outline when Reduce Motion is on (spec 6.2).
struct Blink: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if !active {
            content
        } else if reduceMotion {
            content.overlay(RoundedRectangle(cornerRadius: 8).stroke(.green, lineWidth: 2))
        } else {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                content.opacity(Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 1 : 0.3)
            }
        }
    }
}

extension View {
    func blink(_ active: Bool) -> some View {
        modifier(Blink(active: active))
    }
}
