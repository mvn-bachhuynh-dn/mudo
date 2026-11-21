# iPhone widgets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Home screen and lock screen widgets for the iPhone app: the active cswap account of a chosen server and its 3 most recent sessions.

**Architecture:** New pure logic in `MuDoCore` (`RecentSessions`, `SessionSnapshot`, a timeout on `CswapClient`), tested on Linux. The server list and tokens move to an App Group (shared defaults and a Keychain access group) so a new WidgetKit extension `MuDoWidget` can read them; shared Swift code lives in `app/ios/Shared`. The widget fetches `GET /v1/cswap` and the first `snapshot` of `GET /v1/stream` itself. Spec: `docs/superpowers/specs/2026-11-21-ios-widget-design.md`.

**Tech Stack:** Swift 6.2 (language mode 6), SwiftUI, WidgetKit, AppIntents (iOS 17), XcodeGen, Swift Testing.

## Global Constraints

- `MuDoCore` must stay buildable on Linux and iOS (no UIKit/AppKit/Security/WidgetKit there).
- Public repo: no real IPs, hostnames, tokens or emails (placeholders `100.64.0.10`, `fd7a:115c:a1e0::10`, `fake-token`).
- No `mudod` change. iOS 17 minimum. App Group `group.dev.steve.MuDoPhone`; widget bundle id `dev.steve.MuDoPhone.Widget`; app bundle id `dev.steve.MuDoPhone` (unchanged).
- Recent sessions: `waiting` first (newest `stateSince` first), then the others except `ended` (newest first); 3 rows.
- Widgets: home small/medium/large, lock rectangular/circular/inline (see the spec table); configuration: server (default: first server) and, lock rectangle only, content Account or Sessions; refresh requested after 15 minutes (5 minutes after a failure); a tap opens `mudo://open?tab=accounts|sessions`.
- Tokens never leave the Keychain; after the update existing servers and tokens must keep working (migration + fallback to the legacy item).
- Conventional Commits, branch `feat/ios-widget`, no push to `main`.
- Verification: Linux `app/scripts/docker-test` for `MuDoCore`; iOS compile in GitHub CI (`make -C app ios-core ios-app`, which builds the app and the embedded extension for the Simulator without signing) after the branch is pushed in a PR; a real iPhone install by script, then the owner confirms the widgets.

---

### Task 1: Pure logic in MuDoCore

**Files:**
- Create: `app/Sources/MuDoCore/RecentSessions.swift`, `app/Sources/MuDoCore/SessionSnapshot.swift`
- Modify: `app/Sources/MuDoCore/CswapClient.swift` (init takes a timeout)
- Test: `app/Tests/MuDoCoreTests/RecentSessionsTests.swift`, `app/Tests/MuDoCoreTests/SessionSnapshotTests.swift`, `app/Tests/MuDoCoreTests/CswapClientTests.swift` (one added test, inside the existing `extension StubHTTPTests`)

**Interfaces:**
- Produces: `RecentSessions.pick(_ sessions: [Session], count: Int = 3) -> [Session]`; `SessionSnapshot.first(from: AsyncThrowingStream<SSEEvent, any Error>) async throws -> [Session]?`; `SessionSnapshot.fetch(daemon: URL, token: String, transport: any EventTransport, timeout: Duration = .seconds(10)) async -> Result<[Session], SessionSnapshot.Failure>`; `SessionSnapshot.Failure: Error, Equatable, Sendable` with cases `unauthorized`, `http(Int)`, `timeout`, `noSnapshot`, `other(String)` and `var message: String` ("token invalid", "HTTP <code>", "timed out", "no data", the text); `CswapClient.init(session: URLSession = .shared, timeout: TimeInterval = 25)`.

- [ ] **Step 1: Write the failing tests**

`app/Tests/MuDoCoreTests/RecentSessionsTests.swift`:

```swift
import Foundation
import Testing
@testable import MuDoCore

@Suite struct RecentSessionsTests {
    private func session(_ id: String, _ state: SessionState, minutesAgo: Int) -> Session {
        Session(id: id, agent: "claude", host: "devbox", cwd: "/p/\(id)", project: id, state: state,
                stateSince: Date(timeIntervalSince1970: 1_800_000_000 - Double(minutesAgo) * 60), lastPrompt: "x")
    }

    private func ids(_ list: [Session]) -> [String] { list.map(\.id) }

    @Test func waitingFirstThenNewest() {
        let input = [session("a", .done, minutesAgo: 1), session("b", .waiting, minutesAgo: 30),
                     session("c", .running, minutesAgo: 2), session("d", .waiting, minutesAgo: 10)]
        #expect(ids(RecentSessions.pick(input)) == ["d", "b", "a"])
    }

    @Test func endedSessionsAreSkipped() {
        let input = [session("a", .ended, minutesAgo: 0), session("b", .idle, minutesAgo: 5)]
        #expect(ids(RecentSessions.pick(input)) == ["b"])
    }

    @Test func fewerThanThree() {
        #expect(ids(RecentSessions.pick([session("a", .done, minutesAgo: 1)])) == ["a"])
        #expect(RecentSessions.pick([]).isEmpty)
    }

    @Test func tiesBreakById() {
        let input = [session("b", .done, minutesAgo: 5), session("a", .done, minutesAgo: 5)]
        #expect(ids(RecentSessions.pick(input)) == ["a", "b"])
    }

    @Test func countIsHonored() {
        let input = (0..<6).map { session("s\($0)", .done, minutesAgo: $0) }
        #expect(ids(RecentSessions.pick(input, count: 2)) == ["s0", "s1"])
    }
}
```

`app/Tests/MuDoCoreTests/SessionSnapshotTests.swift`:

```swift
import Foundation
import Testing
@testable import MuDoCore

@Suite struct SessionSnapshotTests {
    private static let snapshotJSON = """
    {"server_now":"2026-11-21T01:00:00Z","host":"devbox","sessions":[{"id":"s1","agent":"claude","host":"devbox","cwd":"/p","project":"p","state":"waiting","state_since":"2026-11-21T00:59:00Z","last_prompt":"hi"}]}
    """
    private static let pingJSON = "{\"server_now\":\"2026-11-21T01:00:00Z\"}"

    private struct FakeTransport: EventTransport {
        var events: [SSEEvent] = []
        var error: (any Error)?
        var hangs = false
        func events(url: URL, token: String) -> AsyncThrowingStream<SSEEvent, any Error> {
            AsyncThrowingStream { continuation in
                if hangs { return }
                for e in events { continuation.yield(e) }
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
        }
    }

    private let daemon = URL(string: "http://100.64.0.10:7879")!

    @Test func firstReturnsTheSnapshotSessions() async throws {
        let transport = FakeTransport(events: [SSEEvent(event: "ping", data: Self.pingJSON),
                                               SSEEvent(event: "snapshot", data: Self.snapshotJSON)])
        let sessions = try await SessionSnapshot.first(from: transport.events(url: daemon, token: "t"))
        #expect(sessions?.map(\.id) == ["s1"])
    }

    @Test func firstIsNilWithoutASnapshot() async throws {
        let transport = FakeTransport(events: [SSEEvent(event: "ping", data: Self.pingJSON)])
        #expect(try await SessionSnapshot.first(from: transport.events(url: daemon, token: "t")) == nil)
    }

    @Test func fetchReturnsTheSessions() async {
        let transport = FakeTransport(events: [SSEEvent(event: "snapshot", data: Self.snapshotJSON)])
        let result = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport)
        #expect((try? result.get())?.map(\.id) == ["s1"])
    }

    @Test func fetchMapsUnauthorized() async {
        let transport = FakeTransport(error: StreamError.unauthorized)
        guard case .failure(let f) = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport) else {
            Issue.record("expected a failure"); return
        }
        #expect(f == .unauthorized)
        #expect(f.message == "token invalid")
    }

    @Test func fetchMapsHttpErrors() async {
        let transport = FakeTransport(error: StreamError.http(503))
        guard case .failure(let f) = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport) else {
            Issue.record("expected a failure"); return
        }
        #expect(f == .http(503))
        #expect(f.message == "HTTP 503")
    }

    @Test func fetchReportsNoSnapshot() async {
        let transport = FakeTransport(events: [])
        guard case .failure(let f) = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport) else {
            Issue.record("expected a failure"); return
        }
        #expect(f == .noSnapshot)
    }

    @Test func fetchTimesOut() async {
        let transport = FakeTransport(hangs: true)
        guard case .failure(let f) = await SessionSnapshot.fetch(daemon: daemon, token: "t", transport: transport,
                                                                timeout: .milliseconds(100)) else {
            Issue.record("expected a failure"); return
        }
        #expect(f == .timeout)
    }
}
```

Add to `CswapClientTests.swift`, inside the existing `extension StubHTTPTests { @Suite struct CswapClientTests { ... } }` body, one more test (read the file first to match its nesting, helper names and indentation):

```swift
        @Test func timeoutIsConfigurable() async {
            let json = listJSON
            let c = CswapClient(session: StubURLProtocol.session { _ in (200, json) }, timeout: 10)
            _ = await c.list(daemon: daemon, token: "t")
            #expect(StubURLProtocol.requests.first?.timeoutInterval == 10)
        }
```

- [ ] **Step 2: Run to verify it fails**

Run: `app/scripts/docker-test`
Expected: FAIL to compile ("cannot find 'RecentSessions'", "extra argument 'timeout'").

- [ ] **Step 3: Implement**

`app/Sources/MuDoCore/RecentSessions.swift`:

```swift
import Foundation

/// The sessions a widget shows: waiting ones first, then the rest, each group newest state change first.
public enum RecentSessions {
    public static func pick(_ sessions: [Session], count: Int = 3) -> [Session] {
        func newestFirst(_ a: Session, _ b: Session) -> Bool {
            a.stateSince != b.stateSince ? a.stateSince > b.stateSince : a.id < b.id
        }
        let live = sessions.filter { $0.state != .ended }
        let waiting = live.filter { $0.state == .waiting }.sorted(by: newestFirst)
        let others = live.filter { $0.state != .waiting }.sorted(by: newestFirst)
        return Array((waiting + others).prefix(max(0, count)))
    }
}
```

`app/Sources/MuDoCore/SessionSnapshot.swift`:

```swift
import Foundation

/// A one-shot read of a server's sessions: the first `snapshot` event of `GET /v1/stream`.
public enum SessionSnapshot {
    public enum Failure: Error, Equatable, Sendable {
        case unauthorized
        case http(Int)
        case timeout
        case noSnapshot
        case other(String)

        public var message: String {
            switch self {
            case .unauthorized: "token invalid"
            case .http(let code): "HTTP \(code)"
            case .timeout: "timed out"
            case .noSnapshot: "no data"
            case .other(let text): text
            }
        }
    }

    /// The sessions of the first `snapshot` event, or nil when the stream ends without one.
    public static func first(from events: AsyncThrowingStream<SSEEvent, any Error>) async throws -> [Session]? {
        for try await event in events where event.event == "snapshot" {
            if case let .snapshot(_, _, sessions)? = try StreamMessage.decode(event: event.event, data: event.data) {
                return sessions
            }
        }
        return nil
    }

    public static func fetch(daemon: URL, token: String, transport: any EventTransport,
                             timeout: Duration = .seconds(10)) async -> Result<[Session], Failure> {
        let url = daemon.appending(path: "v1/stream")
        return await withTaskGroup(of: Result<[Session], Failure>.self) { group in
            group.addTask {
                do {
                    if let sessions = try await first(from: transport.events(url: url, token: token)) {
                        return .success(sessions)
                    }
                    return .failure(.noSnapshot)
                } catch StreamError.unauthorized {
                    return .failure(.unauthorized)
                } catch StreamError.http(let code) {
                    return .failure(.http(code))
                } catch {
                    return .failure(.other(error.localizedDescription))
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .failure(.timeout)
            }
            let result = await group.next() ?? .failure(.timeout)
            group.cancelAll()
            return result
        }
    }
}
```

In `CswapClient.swift` change the stored properties and init to:

```swift
    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 25) {
        self.session = session
        self.timeout = timeout
    }
```

and `request.timeoutInterval = 25` to `request.timeoutInterval = timeout`.

- [ ] **Step 4: Run to verify it passes**

Run: `app/scripts/docker-test`
Expected: PASS (303 existing tests plus the new ones, none regressed). If `fetchTimesOut` hangs the run, the cause is the fake transport's never-finishing stream not being cancelled: fix the implementation (the group must cancel and return), not the test.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MuDoCore app/Tests/MuDoCoreTests
git commit -m "feat(core): add RecentSessions and SessionSnapshot for the widgets" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: App Group storage, migration and the `mudo://open` link

**Files:**
- Create: `app/ios/Shared/SharedConfig.swift`, `app/ios/Shared/ServerStore.swift`
- Move: `app/ios/MuDoPhone/KeychainStore.swift` to `app/ios/Shared/KeychainStore.swift` (with `git mv`) and rewrite it
- Modify: `app/ios/project.yml` (app sources, entitlements), `.gitignore`
- Modify: `app/ios/MuDoPhone/PhoneModel.swift`, `PhoneCswap.swift`, `AccountsView.swift`, `RootView.swift`

**Interfaces:**
- Produces: `SharedConfig.appGroup: String` (`"group.dev.steve.MuDoPhone"`), `SharedConfig.defaults: UserDefaults`, `SharedConfig.sortKey`; `ServerStore.load() -> [ServerConfig]`, `ServerStore.save(_:)`, `ServerStore.migrateFromStandardDefaults()`; `KeychainStore.read(_ account: String) -> String?`, `write(_:account:) -> Bool`, `delete(account:)`, `migrateToSharedGroup(accounts: [String])`; `PhoneModel.requestedTab: String?`.

- [ ] **Step 1: Shared files**

`app/ios/Shared/SharedConfig.swift`:

```swift
import Foundation

/// What the app and the widget extension share through the App Group.
enum SharedConfig {
    static let appGroup = "group.dev.steve.MuDoPhone"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
    static let sortKey = "sortUsableFirst"
}
```

`app/ios/Shared/ServerStore.swift`:

```swift
import Foundation
import MuDoCore

/// The server list shared by the app and the widget (App Group defaults).
enum ServerStore {
    private static let key = "servers"

    static func load() -> [ServerConfig] {
        guard let data = SharedConfig.defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return [] }
        return saved.filter { !$0.managedLocal }
    }

    static func save(_ servers: [ServerConfig]) {
        if let data = try? JSONEncoder().encode(servers) { SharedConfig.defaults.set(data, forKey: key) }
    }

    /// After an update: copies the list and the sort switch from the standard defaults, once.
    static func migrateFromStandardDefaults() {
        let shared = SharedConfig.defaults
        if shared.data(forKey: key) == nil, let old = UserDefaults.standard.data(forKey: key) {
            shared.set(old, forKey: key)
        }
        if shared.object(forKey: SharedConfig.sortKey) == nil,
           let sort = UserDefaults.standard.object(forKey: SharedConfig.sortKey) as? Bool {
            shared.set(sort, forKey: SharedConfig.sortKey)
        }
    }
}
```

`app/ios/Shared/KeychainStore.swift` (after `git mv`, replace the whole content): tokens live in the Keychain with the App Group as access group; reads fall back to the legacy item so no server loses its token.

```swift
import Foundation
import Security

/// Server tokens, one generic-password item per server id, in the App Group's keychain access group.
enum KeychainStore {
    private static let service = "dev.steve.MuDoPhone"

    private static func query(_ account: String, shared: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if shared { q[kSecAttrAccessGroup as String] = SharedConfig.appGroup }
        return q
    }

    private static func read(_ account: String, shared: Bool) -> String? {
        var q = query(account, shared: shared)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The shared item first, then the legacy one (an update the app has not migrated yet).
    static func read(_ account: String) -> String? {
        read(account, shared: true) ?? read(account, shared: false)
    }

    /// Writes to the shared group; when that is not possible writes the legacy item so the app keeps working.
    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        if write(value, account: account, shared: true) { return true }
        return write(value, account: account, shared: false)
    }

    private static func write(_ value: String, account: String, shared: Bool) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account, shared: shared) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account, shared: shared)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(query(account, shared: true) as CFDictionary)
        SecItemDelete(query(account, shared: false) as CFDictionary)
    }

    /// Moves legacy items to the shared group. A legacy item is deleted only after the shared copy was written.
    static func migrateToSharedGroup(accounts: [String]) {
        for account in accounts {
            guard read(account, shared: true) == nil, let legacy = read(account, shared: false) else { continue }
            if write(legacy, account: account, shared: true) {
                SecItemDelete(query(account, shared: false) as CFDictionary)
            }
        }
    }
}
```

Note for the implementer: a query without an access group matches items in every group the process can access, so the legacy read may return the shared item too, and the legacy delete after migration could also match the shared item. Make migration safe: after writing the shared copy, delete the legacy item only if you can address it without matching the shared one; otherwise skip the delete (a harmless leftover) and document it in the report. Also, `write(_:account:)` falling back to the legacy item means the widget cannot read that token; that is accepted (the app keeps working).

- [ ] **Step 2: project.yml, entitlements, .gitignore**

In `app/ios/project.yml` target `MuDoPhone`: change `sources: [MuDoPhone]` to `sources: [MuDoPhone, Shared]` and add

```yaml
    entitlements:
      path: MuDoPhone/MuDoPhone.entitlements
      properties:
        com.apple.security.application-groups: [group.dev.steve.MuDoPhone]
```

Append to `.gitignore`: `app/ios/MuDoPhone/MuDoPhone.entitlements`, `app/ios/MuDoWidget/MuDoWidget.entitlements`, `app/ios/MuDoWidget/Info.plist`.

- [ ] **Step 3: App code**

`PhoneModel.swift`: remove the `defaults` property, `serversKey` and the `init(defaults:)` parameter; the init becomes

```swift
    init() {
        store.hideIdleAfter = TimeInterval(IdleFold.defaultHours * 3600)
        ServerStore.migrateFromStandardDefaults()
        servers = ServerStore.load()
        KeychainStore.migrateToSharedGroup(accounts: servers.map { $0.id.uuidString })
        store.setServers(servers)
    }
```

`persist()` becomes `store.setServers(servers); ServerStore.save(servers); WidgetCenter.shared.reloadAllTimelines()` (add `import WidgetKit`). Add `var requestedTab: String?` (observable, next to `pendingDraft`) and extend `handle(url:)`:

```swift
    func handle(url: URL) {
        if let draft = AddLink.parse(url) { pendingDraft = draft; return }
        if url.scheme?.lowercased() == "mudo", url.host?.lowercased() == "open",
           let tab = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "tab" })?.value,
           ["accounts", "sessions"].contains(tab) {
            requestedTab = tab
        }
    }
```

`RootView.swift`: add after the other `.onChange` modifiers

```swift
        .onChange(of: model.requestedTab) { _, requested in
            guard let requested else { return }
            if requested == "accounts" && cswap.sources.isEmpty { model.requestedTab = nil; return }
            tab = requested
            model.requestedTab = nil
        }
```

`PhoneCswap.swift`: `import WidgetKit`; at the end of `switchTo` (after the final refresh and error assignment) add `WidgetCenter.shared.reloadAllTimelines()`.

`AccountsView.swift`: change `@AppStorage("sortUsableFirst") private var usableFirst = true` to `@AppStorage(SharedConfig.sortKey, store: SharedConfig.defaults) private var usableFirst = true`.

- [ ] **Step 4: Verify and commit**

Run `app/scripts/docker-test` (must still pass; `app/ios` is not compiled there). iOS compile happens in CI.

```bash
git add -A app/ios .gitignore
git commit -m "feat(ios): share servers and tokens through an App Group" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The widget extension

**Files:**
- Create: `app/ios/MuDoWidget/MuDoWidgetBundle.swift`, `Intents.swift`, `Entry.swift`, `Loader.swift`, `Provider.swift`, `WidgetViews.swift`
- Modify: `app/ios/project.yml` (new target, app dependency)

**Interfaces:**
- Consumes: `ServerStore.load()`, `KeychainStore.read(_:)`, `SharedConfig`, `CswapClient`, `CswapOrder`, `SessionSnapshot.fetch`, `RecentSessions.pick`, `URLSessionTransport`, `CswapRowModel`, `CswapSeverity`, `ElapsedFormat.short`.
- Produces: the `MuDoWidget` bundle with one widget of kind `dev.steve.MuDoPhone.Widget`.

- [ ] **Step 1: project.yml**

Add the target (same indentation as `MuDoPhone`):

```yaml
  MuDoWidget:
    type: app-extension
    platform: iOS
    sources: [MuDoWidget, Shared]
    dependencies:
      - package: MuDo
        product: MuDoCore
    entitlements:
      path: MuDoWidget/MuDoWidget.entitlements
      properties:
        com.apple.security.application-groups: [group.dev.steve.MuDoPhone]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.steve.MuDoPhone.Widget
        TARGETED_DEVICE_FAMILY: "1"
        SKIP_INSTALL: YES
    info:
      path: MuDoWidget/Info.plist
      properties:
        CFBundleDisplayName: MuDo
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: true
```

and under target `MuDoPhone` `dependencies` add `- target: MuDoWidget` (this embeds the extension).

- [ ] **Step 2: Entry, intents and loader**

`app/ios/MuDoWidget/Entry.swift`:

```swift
import MuDoCore
import WidgetKit

struct MuDoEntry: TimelineEntry {
    let date: Date
    var serverName: String?
    /// Accounts of the server, already sorted for display.
    var accounts: [CswapAccount] = []
    var accountsError: String?
    /// The 3 most recent sessions.
    var sessions: [Session] = []
    var sessionsError: String?
    /// Shown instead of everything else (no server, no token).
    var message: String?
    /// What the lock screen rectangle shows (from the widget configuration).
    var content: ContentChoice = .account

    var active: CswapAccount? { accounts.first { $0.active } }

    static let sample = MuDoEntry(
        date: .now, serverName: "devbox",
        accounts: [
            CswapAccount(number: 1, email: "alex@example.com", organization: "Team Alpha", alias: nil, active: true, status: .ok,
                         windows: [CswapWindow(name: "5h", pct: 18, clock: nil, countdown: "4h 4m"),
                                   CswapWindow(name: "7d", pct: 41, clock: nil, countdown: "5d 11h")], stale: false),
            CswapAccount(number: 2, email: "sam@example.com", organization: "Team Beta", alias: nil, active: false, status: .ok,
                         windows: [CswapWindow(name: "5h", pct: 74, clock: nil, countdown: "4h 4m"),
                                   CswapWindow(name: "7d", pct: 63, clock: nil, countdown: "5d 11h")], stale: false),
            CswapAccount(number: 3, email: "lee@example.com", organization: "Team Gamma", alias: nil, active: false,
                         status: .reloginRequired, windows: [], stale: false),
        ],
        sessions: [
            Session(id: "a", agent: "claude", host: "devbox", cwd: "/p/api", project: "api-gateway", state: .waiting,
                    stateSince: .now.addingTimeInterval(-120), lastPrompt: "refactor auth"),
            Session(id: "b", agent: "kiro", host: "devbox", cwd: "/p/web", project: "web-ui", state: .running,
                    stateSince: .now.addingTimeInterval(-600), lastPrompt: "dark mode"),
            Session(id: "c", agent: "claude", host: "devbox", cwd: "/p/tf", project: "infra-tf", state: .done,
                    stateSince: .now.addingTimeInterval(-3600), lastPrompt: "vpc split"),
        ])
}
```

`app/ios/MuDoWidget/Intents.swift`:

```swift
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
```

`app/ios/MuDoWidget/Loader.swift`:

```swift
import Foundation
import MuDoCore

enum Loader {
    /// Builds the entry for the server with this id, or for the first server when `serverID` is nil or unknown.
    static func load(serverID: String?, content: ContentChoice) async -> MuDoEntry {
        let servers = ServerStore.load()
        guard let config = servers.first(where: { $0.id.uuidString == serverID }) ?? servers.first else {
            return MuDoEntry(date: .now, message: "Open MuDo to add a server", content: content)
        }
        let token = KeychainStore.read(config.id.uuidString) ?? ""
        guard !token.isEmpty else {
            return MuDoEntry(date: .now, serverName: config.name, message: "Open MuDo: token missing", content: content)
        }
        async let accountsResult = CswapClient(timeout: 10).list(daemon: config.daemonURL, token: token)
        async let sessionsResult = SessionSnapshot.fetch(daemon: config.daemonURL, token: token, transport: URLSessionTransport())
        var entry = MuDoEntry(date: .now, serverName: config.name, content: content)
        switch await accountsResult {
        case .success(let list):
            let usableFirst = SharedConfig.defaults.object(forKey: SharedConfig.sortKey) as? Bool ?? true
            entry.accounts = CswapOrder.sorted(list.accounts, usableFirst: usableFirst)
        case .failure(let failure):
            entry.accountsError = failure.message
        }
        switch await sessionsResult {
        case .success(let sessions):
            entry.sessions = RecentSessions.pick(sessions)
        case .failure(let failure):
            entry.sessionsError = failure.message
        }
        return entry
    }
}
```

- [ ] **Step 3: Provider, bundle and views**

`app/ios/MuDoWidget/Provider.swift`:

```swift
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
```

`app/ios/MuDoWidget/MuDoWidgetBundle.swift`:

```swift
import SwiftUI
import WidgetKit

@main
struct MuDoWidgetBundle: WidgetBundle {
    var body: some Widget { MuDoWidget() }
}

struct MuDoWidget: Widget {
    let kind = "dev.steve.MuDoPhone.Widget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectServerIntent.self, provider: Provider()) { entry in
            MuDoWidgetView(entry: entry)
        }
        .configurationDisplayName("MuDo")
        .description("The active cswap account and the latest sessions of a server.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}
```

`app/ios/MuDoWidget/WidgetViews.swift`:

```swift
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
```

- [ ] **Step 4: Verify and commit**

Run `app/scripts/docker-test` (must still pass). The widget is compiled by CI after the push. If you can compile Swift for iOS here, say so; otherwise state that CI is the first compile and check every API against `app/Sources/MuDoCore` (signatures of `CswapRowModel`, `CswapWindow`, `CswapSeverity`, `ElapsedFormat.short`, `Session`, `SessionState`, `CswapAccount` init) and WidgetKit/AppIntents iOS 17 semantics (`containerBackground`, `AppIntentTimelineProvider`, `WidgetConfigurationIntent`, `AppEntity`/`EntityQuery`, `AppEnum` with `static let` display representations under Swift 6).

```bash
git add -A app/ios
git commit -m "feat(ios): add the home screen and lock screen widgets" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Docs

**Files:**
- Modify: `README.md` ("iPhone app" section), `app/README.md`, `CLAUDE.md` (the "iPhone app" section), the spec's Testing section if reality differs.

- [ ] **Step 1: Write the docs**

README "iPhone app": add a **Widgets** bullet: home screen (small, medium, large) and lock screen (rectangular, circular, inline); edit the widget to pick the server (and, on the lock screen rectangle, Account or Sessions); they show the active cswap account and the 3 most recent sessions (waiting first); iOS decides when widgets refresh (the app asks for every 15 minutes, so they are not real time); a tap opens the app; the widgets read the same server list and tokens as the app through an App Group, and the first launch after the update migrates the list and tokens. `app/README.md`: the layout (`app/ios/Shared`, `app/ios/MuDoWidget`), the App Group id, that the extension has its own bundle id and App ID, and that signing for a device needs the team to register the App Group (`-allowProvisioningUpdates`). `CLAUDE.md` "iPhone app": one line that `app/ios/Shared` is compiled into the app and the widget, so keep it free of app-only types.

- [ ] **Step 2: Commit**

```bash
git add README.md app/README.md CLAUDE.md
git commit -m "docs: document the iPhone widgets" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```
