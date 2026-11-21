import AppIntents
import MuDoCore

struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Server"
    static let defaultQuery = ServerQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ServerQuery: EntityQuery {
    private func all() -> [ServerEntity] {
        ServerStore.load().map { ServerEntity(id: $0.id.uuidString, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [ServerEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ServerEntity] { all() }

    func defaultResult() async -> ServerEntity? { all().first }
}

enum ContentChoice: String, AppEnum {
    case account, sessions

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Content"
    static let caseDisplayRepresentations: [ContentChoice: DisplayRepresentation] = [
        .account: "Account", .sessions: "Sessions",
    ]
}

struct SelectServerIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "MuDo"
    static let description = IntentDescription("Choose the server, and what the lock screen widget shows.")

    @Parameter(title: "Server") var server: ServerEntity?
    @Parameter(title: "Lock screen content", default: .account) var content: ContentChoice
}
