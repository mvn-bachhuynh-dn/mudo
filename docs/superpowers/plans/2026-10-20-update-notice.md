# Update notice Implementation Plan

> **For agentic workers:** executed with `/mudo-task` (one task). Steps use checkbox (`- [ ]`) syntax.

**Goal:** MuDo tells the user when a newer release exists on GitHub and how to get it. It never downloads or installs anything itself.

**Architecture:** MuDoCore holds the pure logic: parse the GitHub "latest release" JSON, compare versions, decide when to check, and choose the upgrade action. The MuDo target fetches with `URLSession` on a timer, stores state in `AppSettings`, and shows the notice in the widget, the status menu and Settings.

**Tech Stack:** Swift 6, swift-testing (MuDoCore), SwiftUI/AppKit (MuDo).

## Global Constraints

- Endpoint, exact: `https://api.github.com/repos/mvn-bachhuynh-dn/mudo/releases/latest`, header `Accept: application/vnd.github+json`, no token, timeout 15 s. Response fields used: `tag_name` (e.g. `v0.6.0`), `html_url`. `html_url` is used only if it starts with `https://github.com/mvn-bachhuynh-dn/mudo/releases/`; else the fallback `https://github.com/mvn-bachhuynh-dn/mudo/releases/latest`.
- Versions: `MAJOR.MINOR.PATCH` integers, optional leading `v`; anything else (pre-release suffix, missing part, empty) is not a version and never counts as newer. Current version = `CFBundleShortVersionString`; if that is not a version (e.g. `dev`), never show a notice.
- Schedule: first check 60 s after launch, then whenever 24 h have passed since the last successful check (a timer ticks every hour). A failed check (network, non-200, bad JSON) is retried on the next hourly tick; it never shows an error.
- Settings (UserDefaults): `checkForUpdates` (Bool, default `true`), `lastUpdateCheck` (Date), `latestVersion` (String, last seen newer version, cleared when not newer), `latestReleaseURL` (String), `skippedVersion` (String).
- Notice shown only when `checkForUpdates`, `latestVersion` is newer than the current version, and `latestVersion != skippedVersion`.
- Upgrade action: if `/opt/homebrew/Caskroom/mudo` or `/usr/local/Caskroom/mudo` exists, the app was installed by Homebrew: copy `brew upgrade --cask mudo` to the pasteboard and show `Copied: brew upgrade --cask mudo` for 3 s. Otherwise open the release URL.
- UI copy, exact:
  - Widget (expanded list, first row, above sessions): `MuDo <version> available`, SF Symbol `arrow.down.circle.fill` (blue). Click = upgrade action. A trailing `xmark` button = skip this version (`skippedVersion = version`).
  - Status menu: item `Update to MuDo <version>…` (above the separator) = upgrade action.
  - Settings: Toggle `Check for updates` in the last section (with Launch at login); the footer shows `MuDo <current>` and, when a notice is due, ` · <version> available`.
- No new dependencies. Tests never hit the network or the real filesystem; inject the fetch and the Caskroom check.

---

### Task 1: Update notice

**Files:**
- Create: `app/Sources/MuDoCore/UpdateCheck.swift`
- Create: `app/Tests/MuDoCoreTests/UpdateCheckTests.swift`
- Create: `app/Sources/MuDo/Updater.swift` (`@MainActor @Observable final class Updater`: timer, fetch, state, `upgrade()`, `skip()`)
- Modify: `app/Sources/MuDo/AppSettings.swift`, `AppModel.swift` (own the `Updater`), `Views.swift` (`UpdateRow` in `SessionListView`), `AppDelegate.swift` (menu item), `SettingsView.swift`
- Modify: `README.md` (one line: MuDo checks GitHub once a day and shows a notice; it never installs by itself; turn off in Settings)

**Interfaces (MuDoCore):**
- `public struct AppVersion: Comparable, Sendable { public init?(_ text: String) }` (accepts `0.5.0`, `v0.5.0`; rejects `0.5`, `0.5.0-rc1`, `dev`, `""`).
- `public struct LatestRelease: Equatable, Sendable { public var version: String; public var url: URL }` and `public static func parse(_ data: Data) -> LatestRelease?` on `UpdateCheck` (version without `v`; nil if `tag_name` is not a version; URL rule from Global Constraints).
- `public enum UpdateCheck`:
  - `static func isDue(lastCheck: Date?, now: Date) -> Bool` (nil or ≥ 24 h ago).
  - `static func notice(current: String, latest: String?, skipped: String?, enabled: Bool) -> String?` (the version to show, or nil).
  - `static let brewCommand = "brew upgrade --cask mudo"`.
  - `static let caskrooms = ["/opt/homebrew/Caskroom/mudo", "/usr/local/Caskroom/mudo"]`.
  - `public enum UpgradeAction: Equatable { case copyBrewCommand, openRelease(URL) }` and `static func action(releaseURL: URL, exists: (String) -> Bool) -> UpgradeAction`.

- [ ] **Step 1: Failing tests** in `UpdateCheckTests.swift`: version parsing and ordering (`0.10.0 > 0.9.9`, `v1.0.0 == 1.0.0`, rejects listed above); `parse` of a sample `{"tag_name":"v0.6.0","html_url":"https://github.com/mvn-bachhuynh-dn/mudo/releases/tag/v0.6.0"}`, of a foreign `html_url` (fallback URL), of a bad tag (nil), of non-JSON (nil); `isDue` (nil, 23 h, 24 h); `notice` (newer, equal, older, skipped, disabled, current `dev`, latest nil); `action` with each Caskroom path existing and with none.
- [ ] **Step 2:** `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift test'`, expect compile failure.
- [ ] **Step 3:** Implement MuDoCore per Interfaces, then the app glue per Files and Global Constraints. `Updater` uses `URLSession.shared` and `FileManager.default.fileExists`; it stores `latestVersion`/`latestReleaseURL`/`lastUpdateCheck` only on a successful check.
- [ ] **Step 4:** `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift build && swift test'`, expect PASS with no warnings.
- [ ] **Step 5: Commit** `feat(app): show a notice when a newer release is out`.
