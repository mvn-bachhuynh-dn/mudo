# Multi-display widget Implementation Plan

> **For agentic workers:** executed with `/mudo-task` (one task). Steps use checkbox (`- [ ]`) syntax.

**Goal:** When the Mac has several displays, show one MuDo widget on each display.

**Architecture:** `PanelController` (app/Sources/MuDo/Panel.swift) today drives one `FloatingPanel`. A new `PanelsController` owns one `PanelController` per screen, keyed by the display's UUID, and adds/removes panels when screens change. Each per-screen panel is confined to its screen and remembers its position per screen. Placement and diff logic live in MuDoCore (unit-tested); AppKit glue stays thin.

**Tech Stack:** Swift 6, SwiftUI + AppKit, swift-testing (MuDoCore only).

## Global Constraints

- Setting `showOnAllDisplays` (UserDefaults key `"showOnAllDisplays"`), default `true`; Settings label `Show on all displays`, in a new Settings section titled `Widget` placed before `Alerts`, with caption `One widget per display. Off: a single widget you can move between displays.`
- Off = exactly today's behavior: one panel, free to move between screens, position in the existing key `"panelTopLeft"`.
- On = one panel per `NSScreen`. Positions in UserDefaults key `"panelTopLeftByScreen"`: a dictionary `[displayUUID: [x, y]]` (top-left, AppKit coordinates).
- Display key: `CGDisplayCreateUUIDFromDisplayID` of `NSScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`, as a `CFUUIDCreateString` string; fall back to the decimal display ID when the UUID is nil.
- A per-screen panel without a saved position for its screen: the legacy `"panelTopLeft"` point if it lies on that screen, else that screen's top-right corner inset by 12 pt (same as today's default).
- A per-screen panel dragged (fully or partly) off its screen is clamped back into that screen's visible frame when the drag ends; it never moves to another screen.
- Panels are independent: hover/pin/expand state is per panel (`PanelState` per panel). All panels share the one `AppModel`.
- Screens added/removed (`NSApplication.didChangeScreenParametersNotification`) and toggling the setting take effect immediately, without relaunch. Closed panels are `orderOut` and released; no leaked global event monitors (remove the `NSEvent` global monitor and notification observers when a panel controller is torn down).
- Keep the MuDo target thin; new logic gets a MuDoCore test that fails without it.

---

### Task 1: One widget per display

**Files:**
- Modify: `app/Sources/MuDoCore/Format.swift` (`PanelPlacement`)
- Create: `app/Sources/MuDoCore/PanelScreens.swift`
- Modify: `app/Tests/MuDoCoreTests/FormatTests.swift`
- Create: `app/Tests/MuDoCoreTests/PanelScreensTests.swift`
- Modify: `app/Sources/MuDo/Panel.swift` (`PanelController`: optional screen key, confinement, per-screen position, teardown)
- Create: `app/Sources/MuDo/Panels.swift` (`PanelsController`)
- Modify: `app/Sources/MuDo/AppDelegate.swift`, `app/Sources/MuDo/AppSettings.swift`, `app/Sources/MuDo/AppModel.swift`, `app/Sources/MuDo/SettingsView.swift`
- Modify: `README.md` (Usage: one sentence on multiple displays and the setting)

**Interfaces:**
- Produces (MuDoCore):
  - `PanelPlacement.topLeft(saved: CGPoint?, in screen: CGRect, width: CGFloat, margin: CGFloat = 12) -> CGPoint`: `saved` when the probe point `(x + 10, y - 10)` lies inside `screen`, else `(screen.maxX - width - margin, screen.maxY - margin)`.
  - `public enum PanelScreens { public static func diff(open: Set<String>, screens: [String]) -> (add: [String], remove: [String]) }`: `add` = screens not open, in `screens` order, duplicates dropped; `remove` = open keys not in `screens`, sorted.
- Produces (MuDo): `PanelsController(model:)` with `show()` and `reload()`; `AppSettings.showOnAllDisplays: Bool`; `AppModel.onPanelLayoutChange: (() -> Void)?` called by SettingsView when the toggle changes; AppDelegate wires it to `PanelsController.reload()`.

- [ ] **Step 1: Write failing MuDoCore tests**

In `FormatTests.swift`, `PanelPlacementTests`, add (with `main` and `side` as already defined there):

```swift
    @Test func perScreenKeepsSavedPointOnThatScreen() {
        let p = CGPoint(x: 2000, y: 900)
        #expect(PanelPlacement.topLeft(saved: p, in: side, width: 200) == p)
    }

    @Test func perScreenMovesPointFromOtherScreenToThisTopRight() {
        #expect(PanelPlacement.topLeft(saved: CGPoint(x: 100, y: 800), in: side, width: 200)
                == CGPoint(x: 1440 + 1920 - 200 - 12, y: 1055 - 12))
    }

    @Test func perScreenNoSavedPointUsesTopRight() {
        #expect(PanelPlacement.topLeft(saved: nil, in: main, width: 100, margin: 20)
                == CGPoint(x: 1320, y: 855))
    }
```

`PanelScreensTests.swift`:

```swift
import Testing
@testable import MuDoCore

@Suite struct PanelScreensTests {
    @Test func addsNewScreensInOrder() {
        let d = PanelScreens.diff(open: [], screens: ["B", "A", "B"])
        #expect(d.add == ["B", "A"])
        #expect(d.remove.isEmpty)
    }

    @Test func removesGoneScreensSorted() {
        let d = PanelScreens.diff(open: ["C", "A", "B"], screens: ["B"])
        #expect(d.add.isEmpty)
        #expect(d.remove == ["A", "C"])
    }

    @Test func unchangedIsEmpty() {
        let d = PanelScreens.diff(open: ["A"], screens: ["A"])
        #expect(d.add.isEmpty && d.remove.isEmpty)
    }
}
```

- [ ] **Step 2: Run them, expect compile failure** (`topLeft(saved:in:width:)` and `PanelScreens` missing).

- [ ] **Step 3: Implement the MuDoCore pieces** exactly per Interfaces; reuse the private `contains` helper.

- [ ] **Step 4: Run MuDoCore tests, expect PASS.**

- [ ] **Step 5: App glue**
  - `AppSettings`: `showOnAllDisplays` persisted under `"showOnAllDisplays"`, default `true` when the key is absent (`defaults.object(forKey:) as? Bool ?? true`).
  - `PanelController.init(model:screenKey:defaults:)`, `screenKey: String?` (nil = today's single free panel). With a key: placement uses `topLeft(saved:in:)` with the screen's visible frame and the per-screen dictionary (legacy fallback per Global Constraints); `resize`, `userMoveEnded` and `place` clamp to that screen's visible frame; positions are saved into the dictionary. If its screen is not found, `place()` does nothing (the PanelsController closes it on the next screen change). Add `close()`: `orderOut`, remove the global monitor (`NSEvent.removeMonitor`) and observers.
  - `PanelsController`: holds `[String: PanelController]` (on) or one keyless controller (off). `show()`/`reload()` build the wanted set from `NSScreen.screens` via `PanelScreens.diff`, close removed ones, create and show added ones; switching mode closes all and rebuilds. Observes `didChangeScreenParametersNotification` and calls `reload()` (with a key, `PanelController` no longer observes it itself; keyless keeps today's `place()` on screen change).
  - `AppDelegate`: replace `PanelController` with `PanelsController`; set `model.onPanelLayoutChange = { [weak panels] in panels?.reload() }`.
  - `SettingsView`: the `Widget` section and `.onChange(of: settings.showOnAllDisplays) { model.onPanelLayoutChange?() }`.
  - README Usage: one sentence on the setting.

- [ ] **Step 6: Build and test on the Mac**: `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift build && swift test'`; expect success.

- [ ] **Step 7: Commit**: `feat(app): show the widget on every display`.
