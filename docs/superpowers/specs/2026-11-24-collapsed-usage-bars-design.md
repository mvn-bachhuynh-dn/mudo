# Collapsed widget: usage bars for the active account

## Goal
The Mac widget shows the 5h and 7d usage bars of the active cswap account even when
collapsed (pointer not over it). Today they appear only in the expanded Accounts tab.

## Decisions
- Account shown: the active account of the source the Accounts tab has selected
  (`CswapModel.current`). Local Mac first, as the tab does.
- Windows shown: `5h` and `7d` only, same `UsageBar` look, without the reset countdown
  (the collapsed pill is narrow). Colors follow the existing severity thresholds.
- Hidden when: Accounts tab is off in Settings, cswap is unavailable, no active account,
  or the account has no 5h/7d window. Stale readings are dimmed like in the list.
- Collapsed only: expanded panel already shows the full list.
- Data: cswap refreshes every 60 s in the background (today only on open and while the
  Accounts tab is visible), so the bars stay fresh while collapsed.
- No new setting (YAGNI); the Accounts tab switch already controls cswap UI.

## Components
- `CswapCompact.windows(in:)` (MuDoCore, tested): picks 5h/7d of the active account.
- `CompactUsageView` (MuDo): two thin labeled bars under the pill.
- `RootView`: shows it when `!panel.isExpanded`. `AppModel`: 60 s cswap refresh tick.

## Testing
Unit tests for the picker; macOS build + screenshot on the build Mac.
