# Accounts tab (cswap) design

## Goal

Show the accounts managed by [claude-swap](https://github.com/) (`cswap`) inside the MuDo widget, and switch the active one with a click. Mac only; `cswap` runs on the same Mac as the app.

## Findings

- `cswap list --json` prints `{schemaVersion, activeAccountNumber, accounts[]}`. Each account has `number`, `email`, `organizationName`, `active`, optional `alias`, `usageStatus` (`ok`, `relogin_required`, `unavailable`, `keychain_unavailable`), `usage` (`fiveHour`, `sevenDay`, `scoped[]`, each with `pct`, `clock`, `countdown`) and `lastGoodUsage` when the live fetch failed.
- `cswap switch <num>` makes that account the active one for new Claude Code sessions. Sessions already running keep their account.
- On the target Mac `cswap` lives at `~/.local/bin/cswap` (a pipx launcher). The app is not started from a login shell, so `PATH` is not reliable.

## Decisions

1. **Where**: a second tab in the expanded widget, next to the session list. Tab bar shows only when `cswap` is found; otherwise the widget looks exactly as before.
2. **Binary**: only fixed, known paths (`~/.local/bin/cswap`, `/opt/homebrew/bin/cswap`, `/usr/local/bin/cswap`), checked for the executable bit. Never a path from the network or a setting (same rule as `TmuxPick`).
3. **Data**: run `cswap list --json` without a shell, 20 s timeout. Refresh when the tab opens and every 60 s while it is visible, plus after a switch. cswap caches usage itself, so this is cheap.
4. **Switch**: click an inactive row, run `cswap switch <number>` (the number is an `Int`, never free text), then refresh. Show the error line (first line of stderr) on failure. Rows with `relogin_required` are not switchable; the row says to log in again with Claude Code and run `cswap add`.
5. **Row**: title = alias, else email; subtitle = organization; two bars, 5h and 7d (plus scoped limits as small text); the active row has a check. Percent colors: under 70 green, 70 to 89 orange, 90 and up red. Stale data (`lastGoodUsage`) is dimmed and marked.
6. **Setting**: "Show Accounts tab" (default on). Off hides the tab and stops polling.
7. **Not in scope**: add, remove, thresholds, priorities. YAGNI; `cswap` in a terminal does those.

## Revision after first use (2026-11-08)

The first version assumed `cswap` runs on the Mac only. In use, the owner's `cswap` also lives on the Linux server, with its own account list (10 accounts, a different active one and order than the Mac's 7). A click in the widget switched the Mac, so `cswap list` on the server did not change. Changes:

- **Sources.** The tab has one source per machine that has `cswap`: This Mac (the binary, as before) and every non-managed-local server. A segmented picker (shown with 2 or more sources) selects one; a line says which machine a click switches. Lists are never merged, because the account numbers mean different accounts on each machine.
- **Server access via `mudod`**, not SSH. New token-protected endpoints `GET /v1/cswap` (output of `cswap list --json`) and `POST /v1/cswap/switch/{number}` (1 to 3 digits, else 400; 502 with cswap's first error line on failure; 404 when `cswap` is absent, which also means an older `mudod`). `mudod` finds `cswap` in the same fixed folders at start, runs one command at a time with a 20 s limit, and never takes arguments from a request as free text. Remote (SSH) `cswap` stays out of scope.
- **Availability.** The tab shows when `cswap` is on the Mac or at least one server answers `/v1/cswap`; a server answering 404 is left out of the picker.
- **Scrolling.** Account and session lists sit in a `ScrollView` capped at about 70 % of the main screen height, so a long list no longer runs off the screen.
- **Signing note (separate cause, same release).** Keychain "Always Allow" prompts on every update came from the self-signed identity having no Team ID; see `app/README.md`, "Signing identity".

## Architecture

- `MuDoCore/Cswap.swift` (pure, tested): `CswapList.parse`, `CswapAccount`, `CswapRowModel` (display logic), `CswapPaths.candidates`, `CswapCommand` argument builders.
- `MuDo/CswapModel.swift` (glue): finds the binary, runs the process off the main actor, holds `accounts`, `error`, `switching`.
- `MuDo/Views.swift`: `PanelTab` picker in `RootView`, `AccountListView`.
- `MuDo/AppSettings.swift`, `SettingsView.swift`: the toggle.

## Errors

Missing binary: no tab. Non-zero exit or unparsable JSON: the tab shows the message and keeps the last good list. A switch in flight disables all rows.

## Testing

MuDoCore unit tests: parsing (ok, relogin, keychain_unavailable with last-good usage, missing fields, wrong schema), row model (title, colors, stale, switchable), path candidates, switch arguments. UI checked on the Mac with the real `cswap` and a screenshot. Test fixtures use placeholder emails (`user@example.com`).
