import CoreGraphics
import Testing
@testable import MuDoCore

@Suite struct PanelDragTests {
    @Test func smallMovesStayAClick() {
        #expect(!PanelDrag.started(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 10, y: 10)))
        #expect(!PanelDrag.started(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 12, y: 12)))
        #expect(!PanelDrag.started(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 13, y: 10)))
    }

    @Test func largerMovesStartADrag() {
        #expect(PanelDrag.started(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 13.5, y: 10)))
        #expect(PanelDrag.started(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 7, y: 7)))
    }
}
