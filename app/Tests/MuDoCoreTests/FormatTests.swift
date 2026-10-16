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
}
