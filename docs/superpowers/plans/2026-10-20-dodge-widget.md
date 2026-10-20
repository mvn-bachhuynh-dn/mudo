# Dodge widget Implementation Plan

> **For agentic workers:** executed with `/mudo-task` (one task). Steps use checkbox (`- [ ]`) syntax.

**Goal:** The collapsed widget gets out of the way when the pointer reaches it on the way to something underneath. It slides away once. Reaching it again at its new spot within a short window means the user wants the widget, and it expands there.

**Architecture:** A pure state machine `Dodge` in MuDoCore decides what to do from pointer events, the pointer location and time. `PanelController` (app/Sources/MuDo/Panel.swift) feeds it from the existing `mouseEntered` hook plus a 50 ms pointer poll that runs only while dodged, and carries out the moves. Each per-display panel has its own machine.

**Tech Stack:** Swift 6, swift-testing (MuDoCore), AppKit (MuDo).

## Global Constraints

- Settings (UserDefaults): `dodgeOnHover` (Bool, default `true`), `dodgeWindowMs` (Int, default `500`, allowed 200...2000; out-of-range or missing values read as 500). Settings section `Widget` gets a Toggle `Move aside when the pointer arrives` and, enabled only when the toggle is on, a Stepper `Reach it again within <n> ms to use it` (step 100, range 200...2000), with caption `The collapsed widget slides aside so you can click what is under it. Reach it again quickly to open it.`
- Dodge applies only when the panel is collapsed (not hovering-expanded, not pinned), the setting is on, and no mouse button is pressed (not a drag).
- Dodge position: the home frame moved down by `home.height + 8` pt. If that frame's bottom would go below the confining visible frame's `minY`, move up by the same amount instead; if that also leaves the visible frame, do not dodge (stay home, no state change). Never resize while dodging.
- Moves are animated (`panel.animator().setFrame`, `NSAnimationContext` duration 0.12 s) and done through the existing programmatic-move guard, so they are never saved as the user's position. While dodged or engaged-away-from-home, `resize(to:)` must not save the top-left.
- States and transitions (`now` is a monotonic time in seconds):
  - `home` + pointer enters panel (dodge allowed) → `dodged(at: now)`; action `moveToDodge`.
  - `dodged(at: t)` + pointer enters panel and `now - t <= window` → `engaged`; action `expand` (the panel expands at the dodged spot, as a hover expansion does today).
  - `dodged(at: t)` + tick with the pointer outside `home` inset by -8 pt (i.e. home grown 8 pt each side) and `now - t > window` → `home`; action `moveHome`.
  - `dodged` + tick with the pointer inside grown home → stay (no action), however long.
  - `dodged(at: t)` + pointer enters panel after the window → `engaged`; action `expand` (the pointer travelled there on purpose).
  - `engaged` + panel collapses (hover collapse or unpin) → `home`; action `moveHome`.
  - Any state + setting turned off, display change, or `show()` → `home`, panel placed home without animation.
  - A user drag while dodged or engaged ends the dodge: state `home`, and the dragged position is saved as today.
- The pointer poll (50 ms) runs only in `dodged`; it stops in `home` and `engaged`.
- Keep the MuDo target thin; the machine and the geometry live in MuDoCore with tests.

---

### Task 1: Dodge on first approach

**Files:**
- Create: `app/Sources/MuDoCore/Dodge.swift`
- Create: `app/Tests/MuDoCoreTests/DodgeTests.swift`
- Modify: `app/Sources/MuDo/Panel.swift` (`PanelController`, `PanelState`: a collapse callback `onCollapse` fired when `isExpanded` goes from true to false)
- Modify: `app/Sources/MuDo/AppSettings.swift`, `app/Sources/MuDo/SettingsView.swift`, `app/Sources/MuDo/Panels.swift` / `AppModel.swift` (pass settings to panels; toggling the setting off sends panels home)
- Modify: `README.md` (Usage: two sentences on the dodge and the setting)

**Interfaces (MuDoCore):**
- `public struct Dodge: Equatable, Sendable`
  - `public enum Phase: Equatable, Sendable { case home, dodged(at: Double), engaged }`
  - `public enum Action: Equatable, Sendable { case moveToDodge(CGRect), moveHome, expand }`
  - `public private(set) var phase: Phase` (starts `.home`)
  - `public var window: Double` (seconds)
  - `public mutating func pointerEntered(now: Double, home: CGRect, visible: CGRect, allowed: Bool) -> Action?`
  - `public mutating func tick(pointer: CGPoint, now: Double, home: CGRect) -> Action?`
  - `public mutating func collapsed() -> Action?` (`engaged` → `.moveHome`, else nil)
  - `public mutating func reset()` (→ `.home`, no action)
  - `public static func dodgeFrame(home: CGRect, visible: CGRect, gap: CGFloat = 8) -> CGRect?`
  - `public static func clampWindowMs(_ ms: Int?) -> Int` (nil or outside 200...2000 → 500)

- [ ] **Step 1: Failing tests** in `DodgeTests.swift` covering every transition in Global Constraints, using a home frame at the top-right of a 1440×900 visible frame: dodge moves down by height + 8; a home frame near the bottom dodges up; a visible frame too short for either gives nil and `pointerEntered` returns nil with phase still `.home`; `allowed: false` returns nil; re-entry at 0.4 s with window 0.5 → `.expand`/`.engaged`; tick at 0.6 s with the pointer 20 pt outside home → `.moveHome`/`.home`; tick at 0.6 s with the pointer 5 pt outside home (inside the 8 pt margin) → nil, still dodged; entry at 2 s → `.expand`; `collapsed()` from engaged → `.moveHome`, from home → nil; `clampWindowMs` (nil, 100, 500, 2500, 1200).
- [ ] **Step 2:** `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift test'`, expect compile failure.
- [ ] **Step 3:** Implement `Dodge`, then the glue: `PanelController` keeps `home: NSRect` (the frame before dodging), routes `onPointerEntered` through `Dodge.pointerEntered` first (expand only when the machine returns `.expand` or the panel is not in a dodge flow; when it returns `.moveToDodge`, do NOT call `state.pointerEntered()`), runs the 50 ms poll while dodged, handles `onCollapse`, user drags, `show()`/`place()` and the setting toggle as specified.
- [ ] **Step 4:** `MUDO_MAC=mudo-mac app/scripts/on-mac 'swift build && swift test'`, expect PASS with no warnings.
- [ ] **Step 5: Commit** `feat(app): move the collapsed widget aside when the pointer arrives`.
