import Foundation
import Testing
@testable import MuDoCore

@Suite struct DodgeTests {
    /// 1440×900 visible frame; the collapsed pill at its top-right corner.
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let home = CGRect(x: 1270, y: 860, width: 160, height: 32)
    /// Pointer over the home spot and over the dodged spot.
    let atHome = CGPoint(x: 1350, y: 876)
    let atAway = CGPoint(x: 1350, y: 836)

    func dodged(at t: Double = 0) -> Dodge {
        var d = Dodge(window: 0.5)
        _ = d.pointerEntered(now: t, pointer: atHome, home: home, visible: visible, allowed: true)
        return d
    }

    @Test func dodgeFrameMovesDownByHeightPlusGap() {
        #expect(Dodge.dodgeFrame(home: home, visible: visible) == CGRect(x: 1270, y: 820, width: 160, height: 32))
    }

    @Test func dodgeFrameNearTheBottomMovesUp() {
        let low = CGRect(x: 10, y: 20, width: 160, height: 32)
        #expect(Dodge.dodgeFrame(home: low, visible: visible) == CGRect(x: 10, y: 60, width: 160, height: 32))
    }

    @Test func noRoomDoesNotDodge() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 50)
        let pill = CGRect(x: 0, y: 10, width: 160, height: 32)
        #expect(Dodge.dodgeFrame(home: pill, visible: short) == nil)
        var d = Dodge(window: 0.5)
        #expect(d.pointerEntered(now: 0, pointer: CGPoint(x: 80, y: 26), home: pill, visible: short, allowed: true) == nil)
        #expect(d.phase == .home)
    }

    @Test func firstEntryDodges() {
        var d = Dodge(window: 0.5)
        #expect(d.phase == .home)
        #expect(d.pointerEntered(now: 3, pointer: atHome, home: home, visible: visible, allowed: true)
            == .moveToDodge(CGRect(x: 1270, y: 820, width: 160, height: 32)))
        #expect(d.phase == .dodged(at: 3))
    }

    @Test func notAllowedDoesNothing() {
        var d = Dodge(window: 0.5)
        #expect(d.pointerEntered(now: 0, pointer: atHome, home: home, visible: visible, allowed: false) == nil)
        #expect(d.phase == .home)
    }

    @Test func reentryWithinWindowExpands() {
        var d = dodged()
        #expect(d.pointerEntered(now: 0.4, pointer: atAway, home: home, visible: visible, allowed: true) == .expand)
        #expect(d.phase == .engaged)
    }

    /// AppKit reports an entry again as the panel starts moving, with the pointer still at home.
    @Test func entryWithPointerStillAtHomeIsIgnored() {
        var d = dodged()
        #expect(d.pointerEntered(now: 0, pointer: atHome, home: home, visible: visible, allowed: true) == nil)
        #expect(d.phase == .dodged(at: 0))
        #expect(d.tick(pointer: atHome, now: 5, home: home) == nil)
        #expect(d.phase == .dodged(at: 0))
    }

    @Test func reentryAfterWindowExpands() {
        var d = dodged()
        #expect(d.pointerEntered(now: 2, pointer: atAway, home: home, visible: visible, allowed: true) == .expand)
        #expect(d.phase == .engaged)
    }

    @Test func pointerFarAwayAfterWindowGoesHome() {
        var d = dodged()
        let p = CGPoint(x: home.minX - 20, y: home.midY)
        #expect(d.tick(pointer: p, now: 0.6, home: home) == .moveHome)
        #expect(d.phase == .home)
    }

    @Test func pointerFarAwayWithinWindowStays() {
        var d = dodged()
        let p = CGPoint(x: home.minX - 20, y: home.midY)
        #expect(d.tick(pointer: p, now: 0.3, home: home) == nil)
        #expect(d.phase == .dodged(at: 0))
    }

    @Test func pointerInsideMarginStaysDodged() {
        var d = dodged()
        let p = CGPoint(x: home.minX - 5, y: home.midY)
        #expect(d.tick(pointer: p, now: 0.6, home: home) == nil)
        #expect(d.tick(pointer: CGPoint(x: home.midX, y: home.midY), now: 60, home: home) == nil)
        #expect(d.phase == .dodged(at: 0))
    }

    @Test func tickOutsideDodgedDoesNothing() {
        var d = Dodge(window: 0.5)
        #expect(d.tick(pointer: .zero, now: 9, home: home) == nil)
        #expect(d.phase == .home)
    }

    @Test func collapseWhenEngagedGoesHome() {
        var d = dodged()
        _ = d.pointerEntered(now: 0.2, pointer: atAway, home: home, visible: visible, allowed: true)
        #expect(d.collapsed() == .moveHome)
        #expect(d.phase == .home)
        #expect(d.collapsed() == nil)
    }

    @Test func collapseFromHomeOrDodgedDoesNothing() {
        var d = Dodge(window: 0.5)
        #expect(d.collapsed() == nil)
        d = dodged()
        #expect(d.collapsed() == nil)
        #expect(d.phase == .dodged(at: 0))
    }

    @Test func resetGoesHome() {
        var d = dodged()
        d.reset()
        #expect(d.phase == .home)
    }

    @Test func clampWindowMs() {
        #expect(Dodge.clampWindowMs(nil) == 500)
        #expect(Dodge.clampWindowMs(100) == 500)
        #expect(Dodge.clampWindowMs(500) == 500)
        #expect(Dodge.clampWindowMs(2500) == 500)
        #expect(Dodge.clampWindowMs(1200) == 1200)
    }
}
