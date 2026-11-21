# Sort the cswap accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show working cswap accounts first and accounts that need a new login last, in the Mac widget and the iPhone app, with a switch (default on).

**Architecture:** One pure function in `MuDoCore` (`CswapOrder.sorted`), applied at display time by the Mac `AccountListView` and the iPhone `AccountsView`; a setting in each app. Spec: `docs/superpowers/specs/2026-11-21-cswap-sort-design.md`.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing.

## Global Constraints

- `MuDoCore` stays buildable on Linux and iOS (no UIKit/AppKit/Security there).
- Public repo: no real IPs, hostnames, tokens or emails.
- Order when on: active first, then `ok`, then `unavailable`, then `relogin_required`; list order (by number) inside a group; off = exact input order.
- The sort is applied when displaying; loaders and `CswapList.parse` are unchanged; switching goes by account number.
- Default on in both apps. Mac key `sortAccountsUsableFirst`, iPhone `@AppStorage("sortUsableFirst")`.
- Conventional Commits, branch `feat/cswap-sort`, no push to `main`.
- Verification: Linux `app/scripts/docker-test`; Mac/iOS compile in GitHub CI (`make -C app test app ios-core ios-app`) once the branch is pushed in a PR.

---

### Task 1: `CswapOrder` in MuDoCore

**Files:**
- Create: `app/Sources/MuDoCore/CswapOrder.swift`
- Test: `app/Tests/MuDoCoreTests/CswapOrderTests.swift`

**Interfaces:**
- Produces: `public enum CswapOrder { public static func sorted(_ accounts: [CswapAccount], usableFirst: Bool) -> [CswapAccount] }`.
- Consumes: `CswapAccount` (`number`, `active`, `status` with cases `.ok`, `.unavailable`, `.reloginRequired`); its memberwise init `CswapAccount(number:email:organization:alias:active:status:windows:stale:)` is internal, available to tests through `@testable import MuDoCore`.

- [ ] **Step 1: Write the failing tests**

`app/Tests/MuDoCoreTests/CswapOrderTests.swift`:

```swift
import Testing
@testable import MuDoCore

@Suite struct CswapOrderTests {
    private func account(_ number: Int, _ status: CswapAccount.Status = .ok, active: Bool = false) -> CswapAccount {
        CswapAccount(number: number, email: "a\(number)@example.com", organization: "", alias: nil,
                     active: active, status: status, windows: [], stale: false)
    }

    private func numbers(_ list: [CswapAccount]) -> [Int] { list.map(\.number) }

    @Test func groupsAreOkThenUnavailableThenRelogin() {
        let input = [account(1, .reloginRequired), account(2, .unavailable), account(3), account(4, .reloginRequired), account(5)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [3, 5, 2, 1, 4])
    }

    @Test func activeAccountComesFirst() {
        let input = [account(1), account(2), account(3, active: true), account(4, .reloginRequired)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [3, 1, 2, 4])
    }

    @Test func activeAccountStaysFirstEvenWhenItNeedsANewLogin() {
        let input = [account(1), account(2, .reloginRequired, active: true), account(3, .unavailable)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [2, 1, 3])
    }

    @Test func listOrderIsKeptInsideAGroup() {
        let input = [account(7), account(2), account(5)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: true)) == [7, 2, 5])
    }

    @Test func offKeepsTheInputOrder() {
        let input = [account(1, .reloginRequired), account(2, active: true), account(3, .unavailable)]
        #expect(numbers(CswapOrder.sorted(input, usableFirst: false)) == [1, 2, 3])
    }

    @Test func emptyAndSingleLists() {
        #expect(CswapOrder.sorted([], usableFirst: true).isEmpty)
        #expect(numbers(CswapOrder.sorted([account(9, .reloginRequired)], usableFirst: true)) == [9])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `app/scripts/docker-test`
Expected: FAIL to compile with "cannot find 'CswapOrder' in scope".

- [ ] **Step 3: Implement**

`app/Sources/MuDoCore/CswapOrder.swift`:

```swift
import Foundation

/// Display order of one machine's cswap accounts.
public enum CswapOrder {
    /// `usableFirst == false` keeps the order of `cswap list`. Otherwise the active account comes
    /// first (even if it needs a new login), then accounts whose usage can be read, then
    /// `unavailable` ones, then `relogin_required` ones; inside a group the input order is kept.
    public static func sorted(_ accounts: [CswapAccount], usableFirst: Bool) -> [CswapAccount] {
        guard usableFirst else { return accounts }
        func rank(_ a: CswapAccount) -> Int {
            if a.active { return 0 }
            switch a.status {
            case .ok: return 1
            case .unavailable: return 2
            case .reloginRequired: return 3
            }
        }
        return accounts.enumerated()
            .sorted { l, r in
                let (a, b) = (rank(l.element), rank(r.element))
                return a != b ? a < b : l.offset < r.offset
            }
            .map(\.element)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `app/scripts/docker-test`
Expected: PASS, `CswapOrderTests` green, no other test regressed.

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MuDoCore/CswapOrder.swift app/Tests/MuDoCoreTests/CswapOrderTests.swift
git commit -m "feat(core): add CswapOrder to sort cswap accounts" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Mac widget setting and view

**Files:**
- Modify: `app/Sources/MuDo/AppSettings.swift` (key next to `showAccounts` ~line 22, property next to `showAccountsTab` ~line 103, init next to line 130)
- Modify: `app/Sources/MuDo/SettingsView.swift` (inside `if model.cswap.available` ~line 126)
- Modify: `app/Sources/MuDo/AccountViews.swift` (`AccountListView`: new `usableFirst` parameter, `ForEach(source.accounts)` ~line 51)
- Modify: `app/Sources/MuDo/Views.swift` (`AccountListView(cswap: model.cswap)` ~line 19)

**Interfaces:**
- Consumes: `CswapOrder.sorted(_:usableFirst:)` from Task 1.
- Produces: `AppSettings.sortAccountsUsableFirst: Bool` (default true), `AccountListView(cswap:usableFirst:)`.

- [ ] **Step 1: Setting**

In `AppSettings.swift`: add `static let sortAccounts = "sortAccountsUsableFirst"` to `Key` next to `showAccounts`; add

```swift
    /// Sort the Accounts tab: active account first, accounts that need a new login last.
    var sortAccountsUsableFirst: Bool {
        didSet { defaults.set(sortAccountsUsableFirst, forKey: Key.sortAccounts) }
    }
```

after `showAccountsTab`; and in `init` next to `showAccountsTab = defaults.object(...)`:

```swift
        sortAccountsUsableFirst = defaults.object(forKey: Key.sortAccounts) as? Bool ?? true
```

- [ ] **Step 2: Settings toggle**

In `SettingsView.swift`, inside `if model.cswap.available { ... }` after the existing toggle:

```swift
                    Toggle("Sort accounts: usable first", isOn: $settings.sortAccountsUsableFirst)
```

- [ ] **Step 3: View**

In `AccountViews.swift` add `let usableFirst: Bool` to `AccountListView` (next to `let cswap: CswapModel`) and change `ForEach(source.accounts)` to `ForEach(CswapOrder.sorted(source.accounts, usableFirst: usableFirst))`. In `Views.swift` change the call to `AccountListView(cswap: model.cswap, usableFirst: model.settings.sortAccountsUsableFirst)` (use the name under which `Views.swift` reaches the settings object; check the surrounding code).

- [ ] **Step 4: Verify and commit**

Run `app/scripts/docker-test` (must still pass; Mac code is compiled by CI). Commit:

```bash
git add app/Sources/MuDo
git commit -m "feat(app): sort the cswap accounts, with a Settings switch" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: iPhone toggle, view and docs

**Files:**
- Modify: `app/ios/MuDoPhone/AccountsView.swift`
- Modify: `README.md` (Accounts tab section and iPhone app section)

**Interfaces:**
- Consumes: `CswapOrder.sorted(_:usableFirst:)`.

- [ ] **Step 1: View**

In `AccountsView.swift` add `@AppStorage("sortUsableFirst") private var usableFirst = true` below the `@State private var confirming`, replace `ForEach(source.accounts)` with `ForEach(CswapOrder.sorted(source.accounts, usableFirst: usableFirst))`, and add to the `NavigationStack` content (next to `.navigationTitle("Accounts")`):

```swift
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Usable accounts first", isOn: $usableFirst)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
```

- [ ] **Step 2: Docs**

README "Accounts tab (cswap)": add a bullet **Order.** By default the active account comes first, then accounts whose usage can be read, then those with unreadable usage, then those that need a new login (inside a group the `cswap list` order is kept); turn off "Sort accounts: usable first" in Settings to see the exact `cswap list` order. README "iPhone app": add one sentence that the Accounts tab sorts the same way and the sort button at the top right of the tab turns it off.

- [ ] **Step 3: Verify and commit**

Run `app/scripts/docker-test`. Commit:

```bash
git add app/ios/MuDoPhone/AccountsView.swift README.md
git commit -m "feat(ios): sort the cswap accounts, with a toggle" -m "Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```
