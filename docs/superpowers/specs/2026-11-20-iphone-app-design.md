# iPhone app design

## Goal

A MuDo app for iPhone: see the agent sessions of all servers, and use the Accounts tab (cswap: usage bars, switch the active account). View and cswap only.

## Decisions

1. **Native SwiftUI app**, sharing `MuDoCore` with the Mac app. Not a PWA: `mudod` rejects browser-style requests and its client API always needs the bearer token, and a page calling several servers cross-origin would force CORS open. Tailscale gives plain HTTP only, so there is no HTTPS either.
2. **Free Apple ID signing.** The app is installed from Xcode on a Mac and must be re-signed every 7 days. No TestFlight, no push.
3. **Network**: the iPhone runs Tailscale and talks to each `mudod` client API (`:7879`) on its tailnet address, IPv4 or the IPv6 form `http://[fd7a:…]:7879`. No new server-side setting.
4. **Scope**: Sessions list, Accounts (cswap) with switching, server management. No notifications, no push, no widget, no click-to-focus, no "This Mac" source, no add/remove of cswap accounts (stays in the `cswap` CLI).
5. **No background mode.** iOS suspends the app, so SSE runs only while the app is active.
6. **No `mudod` changes.** The existing `GET /v1/cswap`, `POST /v1/cswap/switch/{number}` and the session stream are enough. The iPhone app needs `mudod` 0.13.0 or later for Accounts, same as the Mac app.

## Screens

Three tabs: **Sessions | Accounts | Servers**.

- **Sessions.** One list across all servers, like the Mac widget: project, server name, state (`running`, `waiting`, `done`, `idle`), last prompt. Uses `SessionStore` rows, bucket order and the idle fold (`IdleFold`, as on the Mac). Rows are not tappable (no terminal to focus). The list scrolls inside the tab.
- **Accounts.** A menu at the top picks one server; lists are never merged because account numbers mean different accounts on each machine. Rows follow the Mac tab: alias, else email, as title; organization as subtitle; check mark on the active account; 5 h and 7 d bars (green under 70 %, orange from 70 %, red from 90 %); model-scoped limits as small text; reset countdown; stale readings dimmed; `relogin_required` rows not tappable. Pull to refresh, plus an automatic refresh every 60 s while the tab is visible and when it opens. Tapping an inactive account shows a confirmation ("Switch to <name> on <server>?"); on confirm it calls `POST /v1/cswap/switch/{number}`, then reloads. A server that answers 404 (no `cswap`, or an older `mudod`) is left out of the menu. The tab is hidden when no server has `cswap`.
- **Servers.** Rows with name and online/offline state. `+` offers two ways: paste a `mudo://add?…` link, or fill in name, URL and token. Opening a `mudo://add?…` link from Notes or Safari opens the same confirmation sheet, parsed by the existing `AddLink.parse`. Swipe to delete. Tokens live in the Keychain; the server list (without tokens) in `UserDefaults`. Empty state on first launch: the Servers tab with a short how-to.

## Architecture

- `app/Package.swift`: add `.iOS(.v17)` to `platforms`. Mac-only files in `MuDoCore` (`TabMatcher`, `TerminalScripts`, `ProcessTree`, `LocalDaemonLogic`, and any other that does not build for iOS) go behind `#if os(macOS)` or move to a macOS-only target. Which files need it is settled by building for the iOS Simulator; nothing is assumed in advance.
- `MuDoCore/CswapClient.swift` (new, tested): the HTTP part of `CswapModel` moved down (`GET /v1/cswap`, `POST /v1/cswap/switch/{number}`, status code to error mapping: 200/204 ok, 404 not available, 401 "token invalid", other: first line of the body). The number stays an `Int`. The Mac `CswapModel` calls it, so there is one implementation.
- `ios/`: Xcode project `MuDoPhone` (SwiftUI app target) depending on the local `MuDoCore` package. Files: `PhoneModel` (`@Observable`: servers, one `ServerConnection` per server, one shared `SessionStore`), `SessionsView`, `AccountsView`, `ServersView`, `KeychainStore`. The team and bundle id are set by the user in Xcode (free Apple ID); no signing identity is committed.
- **Connections.** When the scene becomes active: connect every server (backoff as on the Mac, snapshot on connect). When it goes to the background: cancel all. Cswap reloads happen on tab open, pull to refresh, every 60 s while visible, and after a switch.
- **App Transport Security.** `mudod` is plain HTTP, so `Info.plist` sets `NSAllowsArbitraryLoads`, the same as the Mac app. `NSAllowsLocalNetworking` could not be tested against Tailscale addresses (`100.64.0.0/10`, `fd7a:…`) and does not cover MagicDNS names, so it is not used. The access control is `mudod`'s token-protected API, and the app sends a token only to servers the user added. `NSLocalNetworkUsageDescription` is set.
- URL scheme `mudo` registered for the add link.

## Errors

- Server unreachable: shown offline, retried with backoff.
- 401: "token invalid" on the server row, no retry loop.
- Switch failure: the error line returned by `mudod` is shown under the picker; the list is unchanged.
- Add link or form with a bad URL or an empty token: rejected with a message (`AddLink.parse` already returns nil).

## Testing

- Unit tests in `MuDoCoreTests` for `CswapClient` (fake `URLProtocol`: 200, 204, 401, 404, 5xx, timeout, request path and headers) and for any logic moved down. They fail without the change. Run with `app/scripts/docker-test` or `on-mac`.
- The iOS target is verified by the GitHub CI compile (`make -C app ios-core ios-app` on a macOS runner) and by a run in the iOS Simulator (iPhone 17, iOS 26.4) against the fake `mudod` on `127.0.0.1` (2026-11-21): adding a server by the form, the Sessions tab with the fake sessions, the Accounts tab with the fake cswap accounts (bars, check mark, a `relogin_required` row dimmed). Not yet tested: a real iPhone, a Tailscale address (the Simulator run used loopback, so App Transport Security over Tailscale is still unverified), the `mudo://add` link (iOS asks "Open in MuDo?" first), and a cswap switch.
- Findings from that run: an unsigned Simulator build (`CODE_SIGNING_ALLOWED=NO`) cannot use the Keychain, so a manual Simulator run needs ad hoc signing (`CODE_SIGN_IDENTITY=-`); the token field made iOS offer to save a password, fixed with `textContentType(.oneTimeCode)`; the first tab-bar tap right after adding a server was swallowed once (not reproduced afterwards, cause unknown).
- Not verifiable from Linux: any iOS build. Installing on a real iPhone is done by the owner from Xcode.
- Public repo rules apply: no real addresses, tokens or hostnames in code, tests, docs or screenshots (`100.64.0.10`, `fd7a:115c:a1e0::10`, `devbox` only).

## Docs

README gets an "iPhone app" section (what it does, Tailscale needed, free Apple ID: re-sign every 7 days, no notifications), `app/README.md` the build steps, and CHANGELOG comes from release-please.

## Out of scope

Notifications and push (need the paid program), widgets, Live Activities, tapping a session to open anything, adding or removing cswap accounts, the "This Mac" source, iPad layout, background refresh.
