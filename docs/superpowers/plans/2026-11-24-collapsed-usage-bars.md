# Collapsed usage bars: plan
1. Test + implement `CswapCompact.windows(in:)` in MuDoCore (docker-test).
2. Add `CompactUsageView`, show in `RootView` when collapsed.
3. Refresh cswap every 60 s from `AppModel.timerFired`.
4. Build on the Mac, screenshot, README note, PR.
