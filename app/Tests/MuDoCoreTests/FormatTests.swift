import Foundation
import Testing
@testable import MuDoCore

@Suite struct ElapsedFormatTests {
    @Test(arguments: [
        (0.0, "0s"), (12.9, "12s"), (59.0, "59s"), (60.0, "1m"), (119.0, "1m"),
        (3599.0, "59m"), (3600.0, "1h"), (3900.0, "1h 5m"), (90000.0, "25h"), (-5.0, "0s"),
    ])
    func formats(seconds: Double, expected: String) {
        #expect(ElapsedFormat.short(seconds) == expected)
    }
}

@Suite struct PanelPlacementTests {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let side = CGRect(x: 1440, y: 0, width: 1920, height: 1055)

    @Test func keepsSavedPointOnAnyScreen() {
        let p = CGPoint(x: 2000, y: 900)
        #expect(PanelPlacement.topLeft(saved: p, screens: [main, side], main: main, width: 200) == p)
    }

    @Test func movesOffscreenPointToMainTopRight() {
        #expect(PanelPlacement.topLeft(saved: CGPoint(x: 5000, y: 900), screens: [main], main: main, width: 200)
                == CGPoint(x: 1440 - 200 - 12, y: 875 - 12))
    }

    @Test func noSavedPointUsesMainTopRight() {
        #expect(PanelPlacement.topLeft(saved: nil, screens: [main], main: main, width: 100, margin: 20)
                == CGPoint(x: 1320, y: 855))
    }

    @Test func noMainScreenKeepsSaved() {
        #expect(PanelPlacement.topLeft(saved: CGPoint(x: 5000, y: 5000), screens: [], main: nil, width: 100)
                == CGPoint(x: 5000, y: 5000))
    }

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

    @Test func clampPullsOffscreenFrameInside() {
        let frame = CGRect(x: 1440, y: 995, width: 160, height: 32)
        #expect(PanelPlacement.clamp(frame, to: main) == CGRect(x: 1280, y: 843, width: 160, height: 32))
    }

    @Test func clampKeepsFrameAlreadyInside() {
        let frame = CGRect(x: 100, y: 100, width: 160, height: 32)
        #expect(PanelPlacement.clamp(frame, to: main) == frame)
    }

    @Test func clampShrinksFrameLargerThanScreen() {
        let frame = CGRect(x: -50, y: -50, width: 2000, height: 1000)
        #expect(PanelPlacement.clamp(frame, to: main) == main)
    }

    @Test func screenContainingCenterWins() {
        let frame = CGRect(x: 1400, y: 500, width: 160, height: 32)  // center x = 1480, on side
        #expect(PanelPlacement.visibleFrame(for: frame, screens: [main, side], main: main) == side)
    }

    @Test func largestIntersectionWhenCenterIsOffscreen() {
        let frame = CGRect(x: 1300, y: 1040, width: 160, height: 40)  // center y = 1060, above both
        #expect(PanelPlacement.visibleFrame(for: frame, screens: [main, side], main: main) == side)
    }

    @Test func mainWhenFrameTouchesNoScreen() {
        let frame = CGRect(x: 9000, y: 9000, width: 160, height: 32)
        #expect(PanelPlacement.visibleFrame(for: frame, screens: [main, side], main: main) == main)
    }
}
