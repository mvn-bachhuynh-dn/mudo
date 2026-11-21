# MuDo (Mac app)

Floating widget that shows Claude Code and Kiro CLI sessions from `mudod` servers.

Overview, install steps, usage and troubleshooting: see the [top-level README](../README.md).

## Build

Needs macOS 26 and Xcode 26 (or its command line tools).

`make app` bundles `Resources/mudod` (the darwin daemon for **Monitor this Mac**) into `MuDo.app/Contents/Resources/mudod` and signs it with `--options runtime`. The Mac has no Go toolchain: run `make -C server app-resource` on the Linux side first, then `scripts/on-mac 'make app'` syncs it over. Without that file `make app` stops with a message.

```bash
make test      # MuDoCore unit tests
make app       # build/MuDo.app, signed with an Apple Development identity if there is one,
               # else "MuDo Dev" if present, else ad-hoc
make install   # copy to /Applications and launch
```

### Signing identity

`make app` picks the first of these (override with `SIGN_ID=...`):

1. A valid **Apple Development** identity in your keychains. It carries a Team ID, so the Keychain keeps "Always Allow" for the server token across rebuilds and updates: macOS identifies the app by Team ID, not by each build's code hash. Sign from a terminal on the Mac, not over SSH: the login keychain is locked there and `codesign` fails with `errSecInternalComponent`. The first build asks once for `codesign` to use the key (Always Allow).
2. The self-signed **"MuDo Dev"** identity from `scripts/make-signing-identity` (below). Same designated requirement for every build, which keeps Automation and Accessibility grants, but it has no Team ID, so the Keychain asks again for every new build (`securityd` logs `ACL partition mismatch`).
3. Ad-hoc (`-`).

The release workflow signs the same way: `MUDO_TEAM_P12` first, then `MUDO_SIGN_P12` (see [CONTRIBUTING.md](../CONTRIBUTING.md)).

#### Self-signed identity (one time)

Run once on the build Mac:

```bash
scripts/make-signing-identity
```

It creates a self-signed code-signing identity "MuDo Dev" in a dedicated keychain `~/Library/Keychains/mudo-signing.keychain-db` (password in `~/.mudo-signing-pass`, mode 600) and adds that keychain to the search list. It is idempotent. `make app` then signs with it (override with `make app SIGN_ID=-`), so every build has the same designated requirement (`certificate leaf = H"..."` instead of a cdhash).

After the first launch with the new signature, click "Always Allow" once on the Keychain prompt for `dev.steve.MuDo`, and allow Automation of Google Chrome once. Later rebuilds keep both and no longer prompt.

From the Linux server, `scripts/on-mac '<command>'` syncs `app/` to the Mac set in `MUDO_MAC=user@host` and runs the command there.

## iPhone app

Layout: `ios/` holds the iPhone app (SwiftUI, generated with XcodeGen from `ios/project.yml`); `MuDoCore` is shared with the Mac app and must build on Linux and iOS (no UIKit, AppKit or Security there).

```bash
make -C app ios-core     # MuDoCore for iOS (needs macOS and Xcode)
make -C app ios-app      # generate the project and build the app for the Simulator
app/scripts/docker-test  # MuDoCore tests on Linux
```

The generated `ios/MuDoPhone.xcodeproj` is git-ignored. `make ios-app` only compiles (`CODE_SIGNING_ALLOWED=NO`): an unsigned app cannot use the Keychain in the Simulator, so adding a server fails with "Could not save the token to the Keychain". To run the app, build it ad hoc signed instead (`xcodebuild ... CODE_SIGN_IDENTITY=-`) or run it from Xcode with a team. For a Simulator run without a real setup, start the fake server and add `http://127.0.0.1:7881` in the app:

```bash
mudod fake --addr 127.0.0.1:7881 --token fake-token --step 3s
```

### Widgets

`ios/MuDoWidget` is the WidgetKit extension (home screen small, medium, large; lock screen rectangular, circular, inline; configured with an App Intent that picks the server). It refreshes every 15 minutes (5 minutes after a failed fetch), as a request to iOS, not a guarantee. A tap opens `mudo://open?tab=accounts` (or `tab=sessions`).

`ios/Shared` is compiled into both the app and the extension: the shared Keychain group constant, the server store and `KeychainStore`. Everything shared is a Keychain item in the access group `<TeamID>.dev.steve.MuDoPhone.shared`: the tokens, the server list (`servers`) and the sort switch (`prefs`). No App Group is used (it needs a portal registration by a team admin). On launch the app copies the server list and the sort switch from the standard defaults (once) and copies legacy Keychain tokens into the shared group; the old token items are left in place, and reads fall back to them if the shared group fails. Not yet verified on a real device.

The extension has its own bundle id (`dev.steve.MuDoPhone.Widget`) and therefore its own App ID; build with `-allowProvisioningUpdates` so Xcode registers it. Keychain access groups need no portal registration. To build under your own team change these locally (do not commit): the app `PRODUCT_BUNDLE_IDENTIFIER`, the widget `PRODUCT_BUNDLE_IDENTIFIER` (it must start with the app id), and the shared group string `dev.steve.MuDoPhone.shared` in `ios/project.yml` (both the `keychain-access-groups` entitlement and the `MuDoSharedKeychainGroup` Info.plist key, of both targets). Keychain Sharing works with any team (unverified on a personal team). The unsigned Simulator build in CI ignores entitlements.

CI builds both the Mac and the iOS targets on `macos-26`. User-facing steps (install, free Apple ID re-signing): see the [top-level README](../README.md#iphone-app).

## Add a server

Run `mudod install --code-server <url>` on the server, then open the printed `mudo://add?...` link on the Mac (or paste it in Settings). Without `--code-server`, fill "code-server URL" in Settings so that clicking a session can focus its Chrome window.

The devbox daemon is reachable on the LAN at `http://192.168.1.10:7879` (Tailscale egress from that server is blocked by Cloudflare WARP).

## Monitor this Mac

Settings → This Mac → **Monitor this Mac** runs the bundled `mudod install --link-only` and adds the server `This Mac` (`http://127.0.0.1:7879`); off runs `mudod uninstall` and removes it only on success. The toggle manages only the server it added (`managedLocal` in the saved config); a loopback server added by hand is still focused as local (`127.0.0.1`, `::1` or `localhost`) but is never installed, upgraded or removed by the toggle. On launch, if the bundled binary's SHA-256 differs from `~/.local/bin/mudod`, the app re-runs install to upgrade it.

## Permissions

- Local and SSH sessions: Automation for iTerm2, Terminal, Ghostty and System Events, and Accessibility for raising VS Code / Cursor / Windsurf / VSCodium / Kiro windows. Each is asked once; a denial is logged under the `focus` category and the click only activates the app.
- First click on a session asks for Automation access to Google Chrome. If denied, MuDo opens a new Chrome window instead, and the menu shows "Allow MuDo to control Chrome…".
- Tokens are stored in the Keychain and read once per server per launch (then cached in memory).
- With an ad-hoc signature, each rebuild changes the signature, so macOS asks again for Keychain access and for Automation access to Google Chrome. Run `scripts/make-signing-identity` once to stop the Automation prompts; to stop the Keychain prompts too, sign with an Apple Development identity (see "Signing identity" above).
- Accounts tab (cswap): the app runs `cswap` only from `~/.local/bin`, `/opt/homebrew/bin` or `/usr/local/bin`, without a shell, and reaches a server's `cswap` only through that server's `mudod` (`/v1/cswap`, bearer token). Switching changes which Claude account new sessions use on that machine.
- If the server has no code-server URL (link printed without `--code-server` and the Settings field empty), clicking a session has no Chrome window to focus and MuDo opens Settings instead. For devbox: `mudod install --code-server https://code.example.com`.
