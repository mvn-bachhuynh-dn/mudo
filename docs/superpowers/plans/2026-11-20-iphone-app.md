# iPhone app Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A SwiftUI iPhone app that lists the agent sessions of all `mudod` servers and shows/switches cswap accounts per server.

**Architecture:** Move the cswap HTTP code and the SSE transport out of the macOS-only `MuDo` target into `MuDoCore` so both apps share them, add iOS to the package platforms, and add a thin SwiftUI app (`app/ios`, target `MuDoPhone`) with three tabs: Sessions, Accounts, Servers. Spec: `docs/superpowers/specs/2026-11-20-iphone-app-design.md`.

**Tech Stack:** Swift 6.2 (language mode 6), SwiftUI, Observation, Swift Testing, XcodeGen (pinned release binary) for the `.xcodeproj`, Xcode 26 and the iOS Simulator on the build Mac.

## Global Constraints

- iOS 17 minimum (`.iOS(.v17)`); Swift language mode 6; `MuDoCore` must still build and test on Linux (`app/scripts/docker-test`), so no `import Security`/`UIKit`/`AppKit` in `MuDoCore`.
- Public repo: no real IP addresses, hostnames, tokens, emails or usernames in code, tests, docs or screenshots. Use `100.64.0.10`, `fd7a:115c:a1e0::10`, `192.168.1.10`, `devbox`, `user@`, `fake-token`.
- No `mudod` (Go) changes. `mudod` 0.13.0+ is needed for Accounts.
- Scope: Sessions list, Accounts (view + switch with confirmation), server management. No notifications, push, widget, click-to-focus, "This Mac" source, add/remove of cswap accounts.
- SSE only while the app is active; cancel connections in the background.
- Tokens in the Keychain, never in `UserDefaults`. No signing identity or team id committed.
- `cswap` account numbers are `Int`, never free text; the account list is never merged across servers.
- Conventional Commits, one logical change per commit, branch `feat/iphone-app`, no push to `main`. `version.txt` is not edited by hand.
- Build Mac: `MUDO_MAC=mudo-mac app/scripts/on-mac '<cmd>'` (syncs `app/` and runs with Xcode 26.4). Linux-side tests: `app/scripts/docker-test`.

## File Structure

| File | Responsibility |
|---|---|
| `app/Sources/MuDoCore/CswapClient.swift` (new) | HTTP calls to a server's `/v1/cswap` endpoints and status-to-error mapping |
| `app/Sources/MuDoCore/CswapSources.swift` (new) | `CswapSource` type (moved) and loading the remote sources for a list of servers |
| `app/Sources/MuDoCore/URLSessionTransport.swift` (new, moved) | SSE `EventTransport` over `URLSession` |
| `app/Tests/MuDoCoreTests/StubURLProtocol.swift` (new) | Test helper that fakes HTTP responses |
| `app/Tests/MuDoCoreTests/CswapClientTests.swift` (new) | Client tests |
| `app/Tests/MuDoCoreTests/CswapSourcesTests.swift` (new) | Source-loader tests |
| `app/Sources/MuDo/CswapModel.swift` | Mac glue, now using the two core types |
| `app/Sources/MuDo/Networking.swift` | Loses `URLSessionTransport` |
| `app/Package.swift`, `app/Makefile`, `.github/workflows/ci.yml` | iOS platform, `ios-core` target, CI step |
| `app/ios/project.yml`, `app/ios/scripts/xcodegen` | XcodeGen spec and pinned downloader |
| `app/ios/MuDoPhone/*.swift` | App: `MuDoPhoneApp`, `PhoneModel`, `KeychainStore`, `RootView`, `ServersView`, `SessionsView`, `PhoneCswap`, `AccountsView` |
| `README.md`, `app/README.md`, `docs/images/iphone-*.png` | Docs and fake-data screenshots |

---

### Task 1: `CswapClient` in MuDoCore

**Files:**
- Create: `app/Sources/MuDoCore/CswapClient.swift`
- Create: `app/Tests/MuDoCoreTests/StubURLProtocol.swift`
- Test: `app/Tests/MuDoCoreTests/CswapClientTests.swift`

**Interfaces:**
- Produces: `public struct CswapClient: Sendable` with `init(session: URLSession = .shared)`, `func list(daemon: URL, token: String) async -> Result<CswapList.Result, CswapClient.Failure>`, `func switchTo(_ number: Int, daemon: URL, token: String) async -> Result<Void, CswapClient.Failure>`; `enum Failure: Error, Equatable, Sendable { case notAvailable; case message(String) }` with `var message: String`.
- Produces (tests): `StubURLProtocol` with `static var handler: (@Sendable (URLRequest) -> (Int, Data))?`, `static var requests: [URLRequest]`, `static func reset()`; a status of `0` makes the load fail with `URLError(.cannotConnectToHost)`.

- [ ] **Step 1: Write the test helper**

`app/Tests/MuDoCoreTests/StubURLProtocol.swift`:

```swift
import Foundation

/// Fakes HTTP for `URLSession` (use with `URLSessionConfiguration.protocolClasses`).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var _requests: [URLRequest] = []

    static var handler: (@Sendable (URLRequest) -> (Int, Data))? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    static var requests: [URLRequest] { lock.withLock { _requests } }
    static func reset() { lock.withLock { _handler = nil; _requests = [] } }

    static func session(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> URLSession {
        reset()
        self.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        guard let handler = Self.handler else { return }
        let (code, body) = handler(request)
        if code == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Write the failing tests**

`app/Tests/MuDoCoreTests/CswapClientTests.swift`:

```swift
import Foundation
import Testing
@testable import MuDoCore

@Suite(.serialized) struct CswapClientTests {
    private let daemon = URL(string: "http://100.64.0.10:7879")!
    private let listJSON = Data("""
    {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
     {"number":2,"email":"user@example.com","organizationName":"Team A","active":true,"usageStatus":"ok",
      "usage":{"fiveHour":{"pct":26.0},"sevenDay":{"pct":95.0}}}]}
    """.utf8)

    private func client(_ handler: @escaping @Sendable (URLRequest) -> (Int, Data)) -> CswapClient {
        CswapClient(session: StubURLProtocol.session(handler))
    }

    @Test func listParsesAccountsAndSendsBearerGET() async throws {
        let json = listJSON
        let c = client { _ in (200, json) }
        let result = try await c.list(daemon: daemon, token: "fake-token").get()
        #expect(result.accounts.map(\.number) == [2])
        #expect(result.activeNumber == 2)
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path == "/v1/cswap")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
    }

    @Test func listWorksWithAnIPv6Daemon() async throws {
        let json = listJSON
        let c = client { _ in (200, json) }
        let v6 = URL(string: "http://[fd7a:115c:a1e0::10]:7879")!
        _ = try await c.list(daemon: v6, token: "t").get()
        #expect(StubURLProtocol.requests.first?.url?.host == "fd7a:115c:a1e0::10")
    }

    @Test func notFoundMeansNotAvailable() async {
        let c = client { _ in (404, Data()) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.notAvailable))
    }

    @Test func unauthorizedSaysTokenInvalid() async {
        let c = client { _ in (401, Data()) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.message("token invalid")))
    }

    @Test func serverErrorShowsFirstBodyLine() async {
        let c = client { _ in (502, Data("cswap exploded\nsecond line".utf8)) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.message("cswap exploded")))
    }

    @Test func emptyErrorBodyShowsStatus() async {
        let c = client { _ in (500, Data()) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.message("HTTP 500")))
    }

    @Test func badJSONIsUnexpectedOutput() async {
        let c = client { _ in (200, Data("nope".utf8)) }
        let r = await c.list(daemon: daemon, token: "t")
        #expect(r == .failure(.message("Unexpected cswap output")))
    }

    @Test func connectionFailureBecomesAMessage() async {
        let c = client { _ in (0, Data()) }
        guard case .failure(.message(let m)) = await c.list(daemon: daemon, token: "t") else {
            Issue.record("expected a message failure"); return
        }
        #expect(!m.isEmpty)
    }

    @Test func switchPostsToTheNumberedPath() async throws {
        let c = client { _ in (204, Data()) }
        try await c.switchTo(3, daemon: daemon, token: "fake-token").get()
        let req = try #require(StubURLProtocol.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/cswap/switch/3")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
    }

    @Test func switchFailureCarriesTheErrorLine() async {
        let c = client { _ in (502, Data("A newer version is available\nno such account".utf8)) }
        let r = await c.switchTo(9, daemon: daemon, token: "t")
        #expect(r == .failure(.message("no such account")))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `app/scripts/docker-test`
Expected: FAIL to compile with "cannot find 'CswapClient' in scope".

- [ ] **Step 4: Write the implementation**

`app/Sources/MuDoCore/CswapClient.swift`:

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to a mudod server's cswap endpoints (`GET /v1/cswap`, `POST /v1/cswap/switch/{number}`).
public struct CswapClient: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// 404: no `cswap` on that server, or a mudod older than 0.13.0.
        case notAvailable
        case message(String)

        public var message: String {
            switch self {
            case .notAvailable: "cswap not available"
            case .message(let m): m
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func list(daemon: URL, token: String) async -> Result<CswapList.Result, Failure> {
        switch await send(daemon: daemon, token: token, path: "v1/cswap", method: "GET") {
        case .success(let data):
            do {
                return .success(try CswapList.parse(data))
            } catch {
                return .failure(.message("Unexpected cswap output"))
            }
        case .failure(let failure):
            return .failure(failure)
        }
    }

    public func switchTo(_ number: Int, daemon: URL, token: String) async -> Result<Void, Failure> {
        await send(daemon: daemon, token: token, path: "v1/cswap/switch/\(number)", method: "POST")
            .map { _ in () }
    }

    private func send(daemon: URL, token: String, path: String, method: String) async -> Result<Data, Failure> {
        var request = URLRequest(url: daemon.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (body, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200, 204: return .success(body)
            case 404: return .failure(.notAvailable)
            case 401: return .failure(.message("token invalid"))
            default:
                let text = String(decoding: body, as: UTF8.self)
                return .failure(.message(CswapCommand.errorLine(text.isEmpty ? "HTTP \(code)" : text)))
            }
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `app/scripts/docker-test`
Expected: PASS, all `CswapClientTests` green, no other test regressed.

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MuDoCore/CswapClient.swift app/Tests/MuDoCoreTests/StubURLProtocol.swift app/Tests/MuDoCoreTests/CswapClientTests.swift
git commit -m "feat(core): add CswapClient for the mudod cswap endpoints" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Shared `CswapSource` loader, Mac app switched to it

**Files:**
- Create: `app/Sources/MuDoCore/CswapSources.swift`
- Test: `app/Tests/MuDoCoreTests/CswapSourcesTests.swift`
- Modify: `app/Sources/MuDo/CswapModel.swift` (struct `CswapSource` at the top, `refresh()` remote loop, `switchTo` remote branch, `RemoteFailure` enum and `remote(...)` function)

**Interfaces:**
- Consumes: `CswapClient`, `ServerConfig(id:name:daemonURL:codeServerURL:)`.
- Produces: `public struct CswapSource: Identifiable, Equatable, Sendable` (`id: String`, `name: String`, `accounts: [CswapAccount]`, `error: String?`, public memberwise `init(id:name:accounts:error:)`); `public enum CswapSources { public static func loadRemote(servers: [(config: ServerConfig, token: String)], client: CswapClient) async -> [CswapSource] }` (keeps server order, drops servers that answer `notAvailable`, keeps a source with `error` for other failures).

- [ ] **Step 1: Write the failing tests**

`app/Tests/MuDoCoreTests/CswapSourcesTests.swift`:

```swift
import Foundation
import Testing
@testable import MuDoCore

@Suite(.serialized) struct CswapSourcesTests {
    private let okJSON = Data("""
    {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
     {"number":1,"email":"user@example.com","organizationName":"","active":true,"usageStatus":"ok",
      "usage":{"fiveHour":{"pct":10.0},"sevenDay":{"pct":20.0}}}]}
    """.utf8)

    private func server(_ name: String, host: String) -> (config: ServerConfig, token: String) {
        (ServerConfig(id: UUID(), name: name, daemonURL: URL(string: "http://\(host):7879")!, codeServerURL: nil), "t")
    }

    @Test func keepsOrderDropsNotAvailableAndKeepsErrors() async {
        let json = okJSON
        let a = server("alpha", host: "100.64.0.1")
        let b = server("beta", host: "100.64.0.2")
        let c = server("gamma", host: "100.64.0.3")
        let d = server("delta", host: "100.64.0.4")
        let client = CswapClient(session: StubURLProtocol.session { req in
            switch req.url?.host {
            case "100.64.0.1", "100.64.0.4": return (200, json)
            case "100.64.0.2": return (404, Data())
            default: return (401, Data())
            }
        })
        let sources = await CswapSources.loadRemote(servers: [a, b, c, d], client: client)
        #expect(sources.map(\.name) == ["alpha", "gamma", "delta"])
        #expect(sources[0].id == a.config.id.uuidString)
        #expect(sources[0].accounts.map(\.number) == [1])
        #expect(sources[0].error == nil)
        #expect(sources[1].accounts.isEmpty)
        #expect(sources[1].error == "token invalid")
        #expect(sources[2].accounts.map(\.number) == [1])
    }

    @Test func noServersGivesNoSources() async {
        let client = CswapClient(session: StubURLProtocol.session { _ in (200, Data()) })
        #expect(await CswapSources.loadRemote(servers: [], client: client).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `app/scripts/docker-test`
Expected: FAIL to compile with "cannot find 'CswapSources' in scope".

- [ ] **Step 3: Write the implementation**

`app/Sources/MuDoCore/CswapSources.swift`:

```swift
import Foundation

/// Where a list of cswap accounts lives: cswap keeps its own accounts per machine, so the Mac
/// and each mudod server that has cswap installed are separate sources.
public struct CswapSource: Identifiable, Equatable, Sendable {
    /// "local" (Mac app only) or the server's UUID string.
    public var id: String
    public var name: String
    public var accounts: [CswapAccount]
    public var error: String?

    public init(id: String, name: String, accounts: [CswapAccount] = [], error: String? = nil) {
        self.id = id
        self.name = name
        self.accounts = accounts
        self.error = error
    }
}

public enum CswapSources {
    /// One source per server that answers `GET /v1/cswap`, in the order of `servers`. A server
    /// without cswap (404, or an older mudod) is left out; any other failure keeps its source with
    /// the error text so the UI can show it.
    public static func loadRemote(servers: [(config: ServerConfig, token: String)],
                                  client: CswapClient) async -> [CswapSource] {
        await withTaskGroup(of: (Int, CswapSource?).self) { group in
            for (index, entry) in servers.enumerated() {
                group.addTask {
                    var source = CswapSource(id: entry.config.id.uuidString, name: entry.config.name)
                    switch await client.list(daemon: entry.config.daemonURL, token: entry.token) {
                    case .success(let result):
                        source.accounts = result.accounts
                    case .failure(.notAvailable):
                        return (index, nil)
                    case .failure(let failure):
                        source.error = failure.message
                    }
                    return (index, source)
                }
            }
            var found: [(Int, CswapSource)] = []
            for await (index, source) in group {
                if let source { found.append((index, source)) }
            }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `app/scripts/docker-test`
Expected: PASS.

- [ ] **Step 5: Switch the Mac `CswapModel` to the shared types**

In `app/Sources/MuDo/CswapModel.swift`:

1. Delete the local `struct CswapSource` and its doc comment (it now lives in `MuDoCore`; the file already has `import MuDoCore`).
2. Add a stored property next to the other `private` ones: `private let client = CswapClient()`.
3. In `refresh()`, replace the whole `for (config, token) in servers() { ... }` loop with:

```swift
next += await CswapSources.loadRemote(servers: servers(), client: client)
```

4. In `switchTo`, replace the `else if let entry = servers().first(...)` branch with:

```swift
} else if let entry = servers().first(where: { $0.config.id.uuidString == source.id }) {
    if case .failure(let e) = await client.switchTo(account.number, daemon: entry.config.daemonURL, token: entry.token) {
        failure = e.message
    }
}
```

5. Delete the `RemoteFailure` enum and the `remote(_:token:path:method:)` function, and the `// MARK: - Remote (mudod)` line above them.

- [ ] **Step 6: Run the Mac build and the full tests**

Run: `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift test && make app SIGN_ID=-'`
Expected: tests pass, `build/MuDo.app` builds with no warnings about unused code.

- [ ] **Step 7: Commit**

```bash
git add app/Sources/MuDoCore/CswapSources.swift app/Tests/MuDoCoreTests/CswapSourcesTests.swift app/Sources/MuDo/CswapModel.swift
git commit -m "refactor(app): move cswap source loading into MuDoCore" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Share the SSE transport

**Files:**
- Create: `app/Sources/MuDoCore/URLSessionTransport.swift`
- Modify: `app/Sources/MuDo/Networking.swift` (remove `URLSessionTransport`)

**Interfaces:**
- Produces: `public struct URLSessionTransport: EventTransport` with `public init()`. Same behavior as the existing Mac type (45 s idle timeout, bearer token, 401 -> `StreamError.unauthorized`, other non-200 -> `StreamError.http`). This is a pure move; the existing `ServerConnectionTests` already cover the consumers with a fake transport, so no new test is added (a live SSE test needs a network).

- [ ] **Step 1: Create the core file**

`app/Sources/MuDoCore/URLSessionTransport.swift`: copy the `URLSessionTransport` struct from `app/Sources/MuDo/Networking.swift` verbatim, then change the declaration to `public struct URLSessionTransport: EventTransport`, add `public init() {}` as its first member, make `events(url:token:)` `public`, and add `#if canImport(FoundationNetworking) import FoundationNetworking #endif` after `import Foundation`.

- [ ] **Step 2: Remove it from the Mac target**

Delete the `struct URLSessionTransport { ... }` block from `app/Sources/MuDo/Networking.swift`; `AppModel` already imports `MuDoCore`, so its `URLSessionTransport()` calls resolve to the core type.

- [ ] **Step 3: Verify**

Run: `app/scripts/docker-test` then `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift test && make app SIGN_ID=-'`
Expected: Linux build compiles `MuDoCore` (if `URLSession.bytes` is unavailable on Linux Foundation, wrap the struct in `#if !os(Linux)`; the tests do not use it) and the Mac build and tests pass.

- [ ] **Step 4: Commit**

```bash
git add app/Sources/MuDoCore/URLSessionTransport.swift app/Sources/MuDo/Networking.swift
git commit -m "refactor(app): move the SSE transport into MuDoCore" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: MuDoCore builds for iOS

**Files:**
- Modify: `app/Package.swift` (platforms)
- Modify: `app/Makefile` (new `ios-core` target)
- Modify: `.github/workflows/ci.yml` (job `app`)
- Modify: any `app/Sources/MuDoCore/*.swift` that fails to compile for iOS (expected candidates: `ProcessTree.swift`, `SSHPick.swift`, `TerminalInfo.swift`, `LocalDaemonLogic.swift`, `TerminalScripts.swift`, `TabMatcher.swift`; the real list is whatever the compiler reports)

**Interfaces:**
- Produces: `make -C app ios-core` builds the `MuDoCore` scheme for the iOS Simulator; later tasks depend on `import MuDoCore` working from an iOS target.

- [ ] **Step 1: Add the platform and the make target**

In `app/Package.swift` change `platforms: [.macOS(.v14)]` to `platforms: [.macOS(.v14), .iOS(.v17)]`.

In `app/Makefile` add `ios-core` to `.PHONY` and this target:

```make
ios-core:
	xcodebuild build -scheme MuDoCore -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 2: Run it and see what breaks**

Run: `MUDO_MAC=mudo-mac app/scripts/on-mac 'make ios-core'`
Expected: possibly FAIL with errors such as "'proc_pidinfo' is unavailable in iOS". The error list is the work list for the next step. If it passes, skip to Step 4.

- [ ] **Step 3: Gate the macOS-only code**

For each file the compiler flags, wrap the offending declarations in `#if os(macOS) ... #endif` (keep the file's tests compiling: put the matching test file's body behind the same `#if`). Do not change behavior on macOS or Linux. Re-run Step 2 until it passes.

- [ ] **Step 4: Check nothing regressed**

Run: `app/scripts/docker-test` and `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift test && make app SIGN_ID=-'`
Expected: both pass.

- [ ] **Step 5: Add the CI step**

In `.github/workflows/ci.yml`, job `app`, after the `make -C app test app SIGN_ID=-` step add:

```yaml
      - run: make -C app ios-core
```

- [ ] **Step 6: Commit**

```bash
git add app/Package.swift app/Makefile .github/workflows/ci.yml app/Sources app/Tests
git commit -m "build(app): build MuDoCore for iOS" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: iOS project, app shell and Servers tab

**Files:**
- Create: `app/ios/scripts/xcodegen`, `app/ios/project.yml`
- Create: `app/ios/MuDoPhone/MuDoPhoneApp.swift`, `PhoneModel.swift`, `KeychainStore.swift`, `RootView.swift`, `ServersView.swift`
- Modify: `.gitignore` (`app/ios/MuDoPhone.xcodeproj/`, `app/ios/.tools/`, `app/ios/MuDoPhone/Info.plist`)

**Interfaces:**
- Produces: `PhoneModel` (`@MainActor @Observable`): `let store: SessionStore`; `private(set) var servers: [ServerConfig]`; `func add(_ draft: ServerDraft)`; `func remove(_ id: UUID)`; `func token(for id: UUID) -> String`; `var cswapServers: [(config: ServerConfig, token: String)]`; `func setActive(_ active: Bool)`; `var pendingDraft: ServerDraft?` (set when a `mudo://add` link opens the app); `func handle(url: URL)`.
- Produces: `KeychainStore.read(_:)`, `write(_:account:)`, `delete(account:)` (service `dev.steve.MuDoPhone`, accessible after first unlock, this device only).

- [ ] **Step 1: Pin and fetch XcodeGen**

The build Mac has no Homebrew, so use the release binary. Find the current release and its asset checksum:

Run: `gh release view --repo yonaskolb/XcodeGen --json tagName,assets --jq '.tagName, (.assets[] | select(.name=="xcodegen.zip") | .digest)'`
Expected: a tag such as `2.xx.x` and a `sha256:...` digest. Write both into `app/ios/scripts/xcodegen`:

```bash
#!/usr/bin/env bash
# Downloads a pinned XcodeGen into app/ios/.tools and runs it. Usage: scripts/xcodegen
set -euo pipefail
VERSION="<tag from gh>"
SHA256="<hex digest from gh, without the sha256: prefix>"
here="$(cd "$(dirname "$0")/.." && pwd)"
bin="$here/.tools/xcodegen/bin/xcodegen"
if [ ! -x "$bin" ]; then
  mkdir -p "$here/.tools"
  curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip" -o "$here/.tools/xcodegen.zip"
  echo "$SHA256  $here/.tools/xcodegen.zip" | shasum -a 256 -c -
  unzip -q -o "$here/.tools/xcodegen.zip" -d "$here/.tools"
fi
cd "$here" && exec "$bin" generate
```

Make it executable (`chmod +x`). The two placeholders in angle brackets are replaced with the values printed by the command above before committing; the committed script contains no angle brackets.

- [ ] **Step 2: Write `project.yml`**

`app/ios/project.yml`:

```yaml
name: MuDoPhone
options:
  deploymentTarget:
    iOS: "17.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    CODE_SIGN_STYLE: Automatic
    DEVELOPMENT_TEAM: ""
packages:
  MuDo:
    path: ..
targets:
  MuDoPhone:
    type: application
    platform: iOS
    sources: [MuDoPhone]
    dependencies:
      - package: MuDo
        product: MuDoCore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.steve.MuDoPhone
        TARGETED_DEVICE_FAMILY: "1"
    info:
      path: MuDoPhone/Info.plist
      properties:
        CFBundleDisplayName: MuDo
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
        NSLocalNetworkUsageDescription: MuDo connects to mudod on your servers to show agent sessions.
        NSAppTransportSecurity:
          NSAllowsLocalNetworking: true
        CFBundleURLTypes:
          - CFBundleURLName: dev.steve.MuDoPhone.add
            CFBundleURLSchemes: [mudo]
```

Append to `.gitignore`: `app/ios/MuDoPhone.xcodeproj/`, `app/ios/.tools/`, `app/ios/MuDoPhone/Info.plist`.

- [ ] **Step 3: Keychain and model**

`app/ios/MuDoPhone/KeychainStore.swift`:

```swift
import Foundation
import Security

/// Server tokens, one generic-password item per server id.
enum KeychainStore {
    private static let service = "dev.steve.MuDoPhone"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
```

`app/ios/MuDoPhone/PhoneModel.swift`:

```swift
import Foundation
import MuDoCore
import Observation

@MainActor
@Observable
final class PhoneModel {
    let store = SessionStore()
    private(set) var servers: [ServerConfig] = []
    /// A server from a `mudo://add` link, waiting for the user to confirm.
    var pendingDraft: ServerDraft?

    @ObservationIgnored private var connections: [UUID: ServerConnection] = [:]
    @ObservationIgnored private var active = false
    @ObservationIgnored private let defaults: UserDefaults
    private static let serversKey = "servers"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        store.hideIdleAfter = TimeInterval(IdleFold.defaultHours * 3600)
        if let data = defaults.data(forKey: Self.serversKey),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved.filter { !$0.managedLocal }
        }
        store.setServers(servers)
    }

    func token(for id: UUID) -> String { KeychainStore.read(id.uuidString) ?? "" }

    var cswapServers: [(config: ServerConfig, token: String)] {
        servers.map { ($0, token(for: $0.id)) }
    }

    func add(_ draft: ServerDraft) {
        let config = ServerConfig(id: UUID(), name: draft.name, daemonURL: draft.daemonURL,
                                  codeServerURL: draft.codeServerURL)
        KeychainStore.write(draft.token, account: config.id.uuidString)
        servers.append(config)
        persist()
        if active { connect(config) }
    }

    func remove(_ id: UUID) {
        connections[id]?.stop()
        connections[id] = nil
        KeychainStore.delete(account: id.uuidString)
        servers.removeAll { $0.id == id }
        persist()
    }

    /// True while the app is in the foreground: connect every server; false: drop all connections.
    func setActive(_ on: Bool) {
        active = on
        if on {
            for config in servers where connections[config.id] == nil { connect(config) }
            for connection in connections.values { connection.reconnectNow() }
        } else {
            for connection in connections.values { connection.stop() }
            connections = [:]
        }
    }

    func handle(url: URL) {
        if let draft = AddLink.parse(url) { pendingDraft = draft }
    }

    private func connect(_ config: ServerConfig) {
        let connection = ServerConnection(config: config, token: token(for: config.id),
                                          store: store, transport: URLSessionTransport())
        connections[config.id] = connection
        connection.start()
    }

    private func persist() {
        store.setServers(servers)
        if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: Self.serversKey) }
    }
}
```

- [ ] **Step 4: App entry, root view, Servers tab**

`app/ios/MuDoPhone/MuDoPhoneApp.swift`:

```swift
import SwiftUI

@main
struct MuDoPhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setActive(phase == .active)
                }
        }
    }
}
```

`app/ios/MuDoPhone/RootView.swift` (Sessions and Accounts views come in Tasks 6 and 7; for this task both tabs are stubbed with `Text`, replaced there):

```swift
import SwiftUI

struct RootView: View {
    let model: PhoneModel
    @State private var tab = "sessions"

    var body: some View {
        TabView(selection: $tab) {
            Text("Sessions").tag("sessions")
                .tabItem { Label("Sessions", systemImage: "list.bullet") }
            ServersView(model: model).tag("servers")
                .tabItem { Label("Servers", systemImage: "server.rack") }
        }
        .onAppear { if model.servers.isEmpty { tab = "servers" } }
    }
}
```

`app/ios/MuDoPhone/ServersView.swift`:

```swift
import MuDoCore
import SwiftUI
import UIKit

struct ServersView: View {
    @Bindable var model: PhoneModel
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                if model.store.servers.isEmpty {
                    Text("Add a server: paste a mudo://add link from `mudod install`, or fill in the address and token. The iPhone must be on the same Tailscale network.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(model.store.servers) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(model.servers.first { $0.id == row.id }?.daemonURL.absoluteString ?? "")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Self.label(row.status)).font(.caption)
                            .foregroundStyle(row.status == .connected ? .green : .secondary)
                    }
                }
                .onDelete { offsets in
                    let rows = model.store.servers
                    for i in offsets { model.remove(rows[i].id) }
                }
            }
            .navigationTitle("Servers")
            .toolbar { Button { showingAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showingAdd) { AddServerView(model: model) }
            .sheet(item: $model.pendingDraft) { draft in AddServerView(model: model, draft: draft) }
        }
    }

    private static func label(_ s: ConnectionStatus) -> String {
        switch s {
        case .connecting: "connecting"
        case .connected: "online"
        case .offline: "offline"
        case .unauthorized: "token invalid"
        }
    }
}

extension ServerDraft: @retroactive Identifiable {
    public var id: String { "\(name)|\(daemonURL.absoluteString)" }
}

struct AddServerView: View {
    let model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var token: String
    @State private var error: String?

    init(model: PhoneModel, draft: ServerDraft? = nil) {
        self.model = model
        _name = State(initialValue: draft?.name ?? "")
        _url = State(initialValue: draft?.daemonURL.absoluteString ?? "")
        _token = State(initialValue: draft?.token ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Paste mudo://add link") {
                        guard let text = UIPasteboard.general.string, let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                              let d = AddLink.parse(u) else { error = "The clipboard has no mudo://add link"; return }
                        name = d.name; url = d.daemonURL.absoluteString; token = d.token; error = nil
                    }
                }
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("http://100.64.0.10:7879", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Token", text: $token)
                }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            .navigationTitle("Add server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let daemon = AddLink.httpURL(url) else { error = "Enter a valid http(s) address"; return }
                        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { error = "The token is empty"; return }
                        let host = URLComponents(url: daemon, resolvingAgainstBaseURL: false)?.host ?? "server"
                        model.add(ServerDraft(name: name.isEmpty ? host : name, daemonURL: daemon, token: trimmed, codeServerURL: nil))
                        dismiss()
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 5: Generate the project and build for the Simulator**

Run: `MUDO_MAC=mudo-mac app/scripts/on-mac 'ios/scripts/xcodegen && xcodebuild build -project ios/MuDoPhone.xcodeproj -scheme MuDoPhone -destination "platform=iOS Simulator,name=iPhone 17" -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO'`
Expected: `** BUILD SUCCEEDED **`. Fix compile errors in this task's files if any (for example `AddLink.httpURL` visibility: it is `public static` in `ServerConfig.swift`).

- [ ] **Step 6: Run it in the Simulator and add a server**

Run on the Mac (`MUDO_MAC=mudo-mac app/scripts/on-mac '<cmd>'`): start a fake server and the app:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
(cd .. && ./mudod fake --addr 127.0.0.1:7881 --token fake-token --step 3s &) 
xcrun simctl boot "iPhone 17" || true
xcrun simctl install booted build/ios/Build/Products/Debug-iphonesimulator/MuDoPhone.app
xcrun simctl launch booted dev.steve.MuDoPhone
xcrun simctl openurl booted 'mudo://add?name=fake&url=http%3A%2F%2F127.0.0.1%3A7881&token=fake-token'
xcrun simctl io booted screenshot ios-servers.png
```

Expected: the confirmation sheet opens pre-filled; after "Add" the Servers tab shows `fake` with `online`. (Use the darwin `mudod` from `make -C server app-resource`, `app/Resources/mudod`, if `./mudod` is not on the Mac.) Stop the fake server afterwards with `kill $(pgrep -x mudod)`.

- [ ] **Step 7: Commit**

```bash
git add app/ios .gitignore
git commit -m "feat(ios): add the iPhone app shell and Servers tab" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Sessions tab

**Files:**
- Create: `app/ios/MuDoPhone/SessionsView.swift`
- Modify: `app/ios/MuDoPhone/RootView.swift` (replace the Sessions stub)

**Interfaces:**
- Consumes: `PhoneModel.store`, `SessionStore.rows`, `SessionRow` (`id`, `session`, `serverName`, `elapsed`, `offline`), `IdleFold.split(_:showAll:)`, `ElapsedFormat.short(_:)`, `SessionStore.hasMultipleServers`, `SessionStore.tick()`.
- Produces: `SessionsView(model:)`.

- [ ] **Step 1: Write the view**

`app/ios/MuDoPhone/SessionsView.swift`:

```swift
import MuDoCore
import SwiftUI

struct SessionsView: View {
    let model: PhoneModel
    @State private var showAllIdle = false

    var body: some View {
        let store = model.store
        let split = IdleFold.split(store.rows, showAll: showAllIdle)
        NavigationStack {
            List {
                if store.rows.isEmpty {
                    Text(model.servers.isEmpty ? "No servers yet. Add one in the Servers tab." : "No sessions.")
                        .foregroundStyle(.secondary)
                }
                ForEach(split.rows) { row in
                    SessionRowView(row: row, showServer: store.hasMultipleServers)
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

    var body: some View {
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
```

In `RootView.swift` replace `Text("Sessions").tag("sessions")` with `SessionsView(model: model).tag("sessions")`.

- [ ] **Step 2: Build and look at it**

Run the Task 5 Step 5 build command, then the Step 6 commands (fake server, install, launch) and screenshot the Sessions tab: `xcrun simctl io booted screenshot ios-sessions.png`; copy it back with `scp mudo-mac:mudo-app/ios-sessions.png /tmp/` and read the image.
Expected: the fake sessions appear with states and prompts, elapsed times update, and `waiting`/`done`/`running` have different dot colors. Only fake data is visible.

- [ ] **Step 3: Commit**

```bash
git add app/ios/MuDoPhone/SessionsView.swift app/ios/MuDoPhone/RootView.swift
git commit -m "feat(ios): add the Sessions tab" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Accounts tab

**Files:**
- Create: `app/ios/MuDoPhone/PhoneCswap.swift`, `app/ios/MuDoPhone/AccountsView.swift`
- Modify: `app/ios/MuDoPhone/RootView.swift`, `app/ios/MuDoPhone/MuDoPhoneApp.swift`

**Interfaces:**
- Consumes: `CswapClient`, `CswapSources.loadRemote`, `CswapSource`, `CswapRowModel`, `CswapSeverity`, `CswapAccount`, `PhoneModel.cswapServers`.
- Produces: `PhoneCswap` (`@MainActor @Observable`): `private(set) var sources: [CswapSource]`, `var selectedID: String`, `private(set) var loading: Bool`, `private(set) var switching: String?`, `var current: CswapSource?`, `func refresh() async`, `func switchTo(_ account: CswapAccount, in source: CswapSource) async`; `AccountsView(model:cswap:)`.

- [ ] **Step 1: Write the model**

`app/ios/MuDoPhone/PhoneCswap.swift`:

```swift
import Foundation
import MuDoCore
import Observation

@MainActor
@Observable
final class PhoneCswap {
    private(set) var sources: [CswapSource] = []
    var selectedID = ""
    private(set) var loading = false
    /// "<source id>/<account number>" while a switch runs.
    private(set) var switching: String?

    @ObservationIgnored private let client = CswapClient()
    @ObservationIgnored private let servers: @MainActor () -> [(config: ServerConfig, token: String)]

    init(servers: @escaping @MainActor () -> [(config: ServerConfig, token: String)]) {
        self.servers = servers
    }

    var current: CswapSource? { sources.first { $0.id == selectedID } ?? sources.first }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        sources = await CswapSources.loadRemote(servers: servers(), client: client)
        if !sources.contains(where: { $0.id == selectedID }), let first = sources.first {
            selectedID = first.id
        }
    }

    func switchTo(_ account: CswapAccount, in source: CswapSource) async {
        guard switching == nil,
              let entry = servers().first(where: { $0.config.id.uuidString == source.id }) else { return }
        switching = "\(source.id)/\(account.number)"
        defer { switching = nil }
        let result = await client.switchTo(account.number, daemon: entry.config.daemonURL, token: entry.token)
        await refresh()
        if case .failure(let failure) = result, let i = sources.firstIndex(where: { $0.id == source.id }) {
            sources[i].error = failure.message
        }
    }
}
```

- [ ] **Step 2: Write the view**

`app/ios/MuDoPhone/AccountsView.swift`:

```swift
import MuDoCore
import SwiftUI

struct AccountsView: View {
    @Bindable var cswap: PhoneCswap
    @State private var confirming: CswapAccount?

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
                    ForEach(source.accounts) { account in
                        AccountRow(account: account, busy: cswap.switching == "\(source.id)/\(account.number)")
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if CswapRowModel(account).switchable, cswap.switching == nil { confirming = account }
                            }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Accounts")
            .refreshable { await cswap.refresh() }
            .task {
                while !Task.isCancelled {
                    await cswap.refresh()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .alert("Switch account?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                   presenting: confirming) { account in
                Button("Switch") {
                    if let source = cswap.current { Task { await cswap.switchTo(account, in: source) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { account in
                Text("Use \(CswapRowModel(account).title) on \(cswap.current?.name ?? "this server"). New Claude Code sessions use it; running ones keep their account.")
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
```

- [ ] **Step 3: Wire it into the app**

In `MuDoPhoneApp.swift` add `@State private var cswap: PhoneCswap` initialised in `init()` from the model: 

```swift
init() {
    let m = PhoneModel()
    _model = State(initialValue: m)
    _cswap = State(initialValue: PhoneCswap(servers: { m.cswapServers }))
}
```

(remove the `= PhoneModel()` default on `model`), pass `cswap` to `RootView(model: model, cswap: cswap)`, and run `Task { await cswap.refresh() }` in the scene-phase handler when `phase == .active`.

In `RootView.swift` add `let cswap: PhoneCswap` and, between the Sessions and Servers tabs:

```swift
if !cswap.sources.isEmpty {
    AccountsView(cswap: cswap).tag("accounts")
        .tabItem { Label("Accounts", systemImage: "person.2") }
}
```

- [ ] **Step 4: Build and exercise it against the fake server**

Run the Task 5 build, then the fake-server steps, open the Accounts tab and take screenshots (`ios-accounts.png`, and one with the confirmation alert), reading each image. Then tap a non-active account, confirm, and check the check mark moved (the fake server's `cswap switch` works).
Expected: five fake accounts, bars colored by severity, the account needing a new login not tappable and dimmed, the alert text names the server, the check mark moves after confirming. A server without cswap (stop the fake and point a second server entry at a closed port) shows no Accounts tab.

- [ ] **Step 5: Commit**

```bash
git add app/ios/MuDoPhone
git commit -m "feat(ios): add the Accounts tab with cswap switching" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 8: App Transport Security over Tailscale, docs, screenshots, PR

**Files:**
- Modify (only if the check fails): `app/ios/project.yml` (`NSAppTransportSecurity`)
- Create: `docs/images/iphone-sessions.png`, `iphone-accounts.png`, `iphone-servers.png`
- Modify: `README.md`, `app/README.md`, `docs/superpowers/specs/2026-11-20-iphone-app-design.md`

- [ ] **Step 1: Test `NSAllowsLocalNetworking` against a Tailscale address**

Find out whether the build Mac has a Tailscale address: `ssh mudo-mac 'tailscale ip -4 2>/dev/null || /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4'`. If it has none, ask the owner for the address of a server in their tailnet and for permission to test against it, and say the result is untested until then. Otherwise run the fake server on `0.0.0.0:7881` on the Mac, and in the Simulator add a server with `http://<that 100.x address>:7881` and token `fake-token`.
Expected: either the server goes `online` (ATS exception is enough) or the Servers row shows a connection error and the log (`xcrun simctl spawn booted log show --last 1m --predicate 'subsystem == "com.apple.network"'`) mentions App Transport Security. Never commit the real address.

- [ ] **Step 2: Apply the fallback only if needed**

If Step 1 failed with ATS, change `NSAppTransportSecurity` in `project.yml` to `NSAllowsArbitraryLoads: true` (the Mac app already uses it), regenerate, rebuild and repeat Step 1. Record which setting worked in the spec's ATS paragraph (replace "It is **not yet known** whether ..." with the measured result).

- [ ] **Step 3: Screenshots**

Take the three screenshots from the Simulator (fake data only: `fake-token`, `127.0.0.1`), check each is under 2000 px on both sides (`sips -g pixelWidth -g pixelHeight`), copy them to `docs/images/iphone-*.png`, and read each image to confirm no real name or address appears.

- [ ] **Step 4: Docs**

README: add an "iPhone app" section after "Accounts tab (cswap)": what it shows (sessions of all servers, cswap accounts with switching), needs (Tailscale on the iPhone, `mudod` 0.13.0+ for Accounts), install (from Xcode with a free Apple ID: `app/ios/scripts/xcodegen`, open `app/ios/MuDoPhone.xcodeproj`, set the team and a unique bundle id, run on the device; re-sign every 7 days), limits (no notifications or push, SSE only while the app is open, no click-to-focus). Embed the three screenshots. `app/README.md`: the build commands (`make -C app ios-core`, XcodeGen, Simulator run, fake server). In the spec, replace "(5 idle rows by default)" with "(`IdleFold`, as on the Mac)".

- [ ] **Step 5: Final verification**

Run: `app/scripts/docker-test`, `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift test && make app SIGN_ID=-'`, the Task 5 Step 5 build, and `git diff origin/main --stat`; scan the diff for IP addresses, hostnames and tokens: `git diff origin/main | grep -nE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|fd7a'` must show only the placeholder addresses listed in Global Constraints.
Expected: everything passes, the scan shows only placeholders.

- [ ] **Step 6: Commit, push the branch and open the PR**

```bash
git add README.md app/README.md docs
git commit -m "docs: document the iPhone app" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

Then, as separate commands: `git push origin feat/iphone-app:feat/iphone-app`, and write the PR body to `.artifacts/pr-body.md` and run `gh pr create --base main --head feat/iphone-app --title "feat(ios): iPhone app for sessions and cswap" --body-file .artifacts/pr-body.md` (body ends with the standard generated-with line). Watch CI with `gh pr checks` in a bounded loop; do not merge (the owner merges).
