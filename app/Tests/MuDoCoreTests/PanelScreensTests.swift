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
