import AppIntents
import WidgetKit

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MuDoEntry { .sample }

    func snapshot(for configuration: SelectServerIntent, in context: Context) async -> MuDoEntry {
        if context.isPreview { return .sample }
        return await Loader.load(serverID: configuration.server?.id, content: configuration.content)
    }

    func timeline(for configuration: SelectServerIntent, in context: Context) async -> Timeline<MuDoEntry> {
        let entry = await Loader.load(serverID: configuration.server?.id, content: configuration.content)
        let failed = entry.message != nil || (entry.accountsError != nil && entry.sessionsError != nil)
        let next = Date().addingTimeInterval(failed ? 5 * 60 : 15 * 60)
        return Timeline(entries: [entry], policy: .after(next))
    }
}
