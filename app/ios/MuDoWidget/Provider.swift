import AppIntents
import WidgetKit

struct Provider: AppIntentTimelineProvider {
    /// Requested refresh interval; iOS decides the real schedule.
    static let refreshInterval: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> MuDoEntry { .sample }

    func snapshot(for configuration: SelectServerIntent, in context: Context) async -> MuDoEntry {
        if context.isPreview { return .sample }
        return await Loader.load(serverID: configuration.server?.id, content: configuration.content)
    }

    func timeline(for configuration: SelectServerIntent, in context: Context) async -> Timeline<MuDoEntry> {
        let entry = await Loader.load(serverID: configuration.server?.id, content: configuration.content)
        let next = Date().addingTimeInterval(Self.refreshInterval)
        return Timeline(entries: [entry], policy: .after(next))
    }
}
