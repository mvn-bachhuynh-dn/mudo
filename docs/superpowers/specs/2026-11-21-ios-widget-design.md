# iPhone widgets (home screen and lock screen)

## Goal

Widgets for the MuDo iPhone app that show the active cswap account of a server and its 3 most recent sessions, on the home screen and the lock screen.

## Decisions

1. **Server choice.** Each widget has a configuration (edit the widget): the **server** it shows (default: the first server in the app) and, for the lock screen rectangle only, the **content** (Account or Sessions). Two widgets can point at two servers.
2. **Families and content.**

   | Widget | Shows |
   |---|---|
   | Home small | The active account of the server: alias or email, 5 h and 7 d bars with %, severity colors as in the app. |
   | Home medium | Left: the same account. Right: the 3 most recent sessions (project, state dot, time since the last state change). |
   | Home large | Up to 5 accounts of the server, sorted with `CswapOrder` (the app's sort switch is honored), each with 5 h and 7 d bars; below, the 3 most recent sessions. |
   | Lock rectangle | Content Account: name and two lines 5 h / 7 d. Content Sessions: 3 lines, project and state. |
   | Lock circular | A gauge for the 5 h usage of the active account, labelled `5h` and the %. |
   | Lock inline | `<name> 5h 18% · 7d 41%` |

3. **"Active account"** is the account with the check mark (`active`) on that server. If it needs a new login or its usage cannot be read, the widget says so instead of showing empty bars.
4. **"3 most recent sessions"**: sessions in state `waiting` first (newest state change first), then all others except `ended` (newest state change first); the first 3. A pure function `RecentSessions.pick(_:count:)` in `MuDoCore`.
5. **Data source, no `mudod` change.** The widget calls `GET /v1/cswap` and reads the first `snapshot` event of `GET /v1/stream` (mudod sends it on connect), then closes the stream: `SessionSnapshot.fetch(daemon:token:)` in `MuDoCore`. Both calls run in parallel with a timeout of about 10 s.
6. **Refresh.** One timeline entry per fetch, next refresh requested after 15 minutes (iOS decides the real schedule and may be slower). On failure: an entry that says `offline`, `token invalid` or `open MuDo to add a server`, retry after 5 minutes. The app calls `WidgetCenter.shared.reloadAllTimelines()` after a server is added or removed and after an account switch. Widgets are not real time.
7. **Tap.** A widget opens the app on the Accounts or Sessions tab through `mudo://open?tab=accounts|sessions`; the app handles it with `onOpenURL` next to the existing `mudo://add` handling.
8. **Sharing data between the app and the extension** (App Group `group.dev.steve.MuDoPhone`):
   - the server list moves from `UserDefaults.standard` to the App Group `UserDefaults`; on first launch after the update the app copies the existing list over;
   - tokens stay in the Keychain but use the App Group as the **keychain access group**; on first launch the app copies existing tokens to it and leaves the old items (a delete without an access group could remove the copy); if the shared group cannot be read the app falls back to the old items so a server never loses its token;
   - the app's account sort switch (`sortUsableFirst`) moves to the same shared defaults;
   - shared Swift code (`KeychainStore`, the server store, the link parsing for `mudo://open`) lives in `app/ios/Shared/`, compiled into both targets; everything else comes from `MuDoCore`.
9. **Extension.** New target `MuDoWidget` (WidgetKit + AppIntents, iOS 17) in `app/ios/project.yml`, bundle id `dev.steve.MuDoPhone.Widget`, embedded in the app, same ATS exception (`NSAllowsArbitraryLoads`) as the app. Configuration intent `SelectServerIntent: WidgetConfigurationIntent` with a `ServerEntity` (`AppEntity`) listing the servers from the shared store.
10. **Signing.** The extension needs its own App ID and the App Group; Xcode registers them with `-allowProvisioningUpdates` and the team already used for the app (`mudo-ios-install.command`). CI keeps building for the Simulator without signing, which ignores entitlements.

## Errors

- No servers: "Open MuDo to add a server". Server removed after the widget was configured: the first server is used, or the same message when there is none.
- Offline, timeout, 401 ("token invalid"), `cswap` missing on the server (404): a short line in the widget's size; for the home medium and large widgets the part that did load is still shown (for example sessions without accounts).
- A fetch never blocks beyond the timeout; stale data is not shown as fresh: every entry shows when it was fetched ("5 min ago") on the home widgets.

## Testing

- `RecentSessions` tests: waiting first, newest first inside both groups, `ended` skipped, fewer than 3, ties.
- `SessionSnapshot` tests with `StubURLProtocol`-style fake data for the SSE parsing of the first `snapshot` event (the transport is `#if !os(Linux)`, so the parsing part is tested through the existing `SSEParser` and `StreamMessage.decode`; the live part is not).
- The widget views and the extension are compiled by CI (`make -C app ios-app`, now including the extension target). Entry building (which entry for which family and data) is plain Swift with unit tests in `MuDoCore` where it does not need WidgetKit.
- Real device: install with `mudo-ios-install.command`; the owner adds the widgets and confirms. The Simulator can show the widgets in the widget gallery; adding them to a screen is manual.

## Docs

README "iPhone app": the widgets, the configuration, the refresh limits, the App Group and the first-launch migration.

## Out of scope

Live Activities, Control Center controls, interactive widgets (switching an account from a widget), StandBy tuning, notifications, a `mudod` change, an iPad layout.

## Risks

The shared Keychain group on a real device is the most likely failure (access group, migration); the fallback keeps existing servers working. iOS may refresh widgets less often than every 15 minutes.
