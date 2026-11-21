# Sort the cswap accounts (Mac widget and iPhone app)

## Goal

Show the accounts that work first and the ones that need a new login last, in both the Mac widget and the iPhone app. On by default; a switch turns it off to see the exact order of `cswap list`.

## Decisions

1. **Order when on:** the active account (check mark) first, even if it needs a new login; then accounts whose usage can be read (`ok`); then `unavailable` (the account exists but its usage cannot be read now); then `relogin_required`. Inside a group the `cswap list` order (by account number) is kept.
2. **Order when off:** exactly the order of `cswap list`.
3. **Where:** a pure function in `MuDoCore`, `CswapOrder.sorted(_:usableFirst:)`, applied when the rows are displayed. The loaders and `CswapList.parse` keep the original order, so the switch takes effect at once and switching still goes by account number.
4. **Mac widget:** a Settings toggle "Sort accounts: usable first" next to "Show Accounts tab (cswap)" (shown when `cswap` is found), default on, stored in `AppSettings` (key `sortAccountsUsableFirst`).
5. **iPhone app:** a small menu button in the Accounts tab toolbar with a toggle "Usable accounts first", default on, remembered with `@AppStorage("sortUsableFirst")`.
6. **Later reuse:** the planned iPhone widget will use the same function to pick the active account.

## Tests

`CswapOrderTests` in `MuDoCoreTests`: active first (also when it needs a new login); `ok`, then `unavailable`, then `relogin_required`; list order kept inside a group; off keeps the input order; empty and single-element lists. The two views are checked by the CI compile (`make -C app test app ios-app`).

## Docs

README: the Accounts section and the iPhone section mention the sort and the switch.

## Out of scope

Sorting by usage percent, pinning accounts, a per-server setting.
