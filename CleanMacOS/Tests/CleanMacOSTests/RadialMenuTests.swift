import CoreGraphics
import Foundation
import Testing
@testable import CleanMacOS

struct RadialMenuTests {
    private let center = CGPoint(x: 200, y: 200)

    @Test func picksTheSliceUnderThePointer() {
        #expect(RadialGeometry.slice(at: CGPoint(x: 200, y: 300), center: center, count: 6) == 0)
        #expect(RadialGeometry.slice(at: CGPoint(x: 300, y: 200), center: center, count: 4) == 1)
        #expect(RadialGeometry.slice(at: CGPoint(x: 200, y: 100), center: center, count: 4) == 2)
        #expect(RadialGeometry.slice(at: CGPoint(x: 100, y: 200), center: center, count: 4) == 3)
        #expect(RadialGeometry.slice(at: CGPoint(x: 215, y: 210), center: center, count: 6) == nil)
        #expect(RadialGeometry.slice(at: CGPoint(x: 250, y: 300), center: center, count: 6) == 0)
        #expect(RadialGeometry.slice(at: CGPoint(x: 300, y: 260), center: center, count: 6) == 1)
        #expect(RadialGeometry.slice(at: CGPoint(x: 300, y: 300), center: center, count: 0) == nil)
    }

    @Test func waitsForRealMovementBeforeHighlighting() {
        var tracker = RadialTracker(origin: center)
        #expect(tracker.highlight(at: CGPoint(x: 204, y: 204), center: center, count: 4) == nil)
        #expect(tracker.highlight(at: CGPoint(x: 200, y: 300), center: center, count: 4) == 0)
        #expect(tracker.highlight(at: CGPoint(x: 210, y: 205), center: center, count: 4) == nil)
    }

    @Test func placesChipsClockwiseFromTheTop() {
        let top = RadialGeometry.chipOffset(index: 0, count: 4, radius: 100)
        #expect(abs(top.x) < 0.001 && abs(top.y - 100) < 0.001)
        let right = RadialGeometry.chipOffset(index: 1, count: 4, radius: 100)
        #expect(abs(right.x - 100) < 0.001 && abs(right.y) < 0.001)
    }

    @Test func movesAroundTheQuickPanelGrid() {
        #expect(GridMove.next(from: 0, key: .right, count: 7, columns: 3) == 1)
        #expect(GridMove.next(from: 2, key: .right, count: 7, columns: 3) == 3)
        #expect(GridMove.next(from: 0, key: .down, count: 7, columns: 3) == 3)
        #expect(GridMove.next(from: 5, key: .down, count: 7, columns: 3) == 6)
        #expect(GridMove.next(from: 6, key: .down, count: 7, columns: 3) == 6)
        #expect(GridMove.next(from: 1, key: .up, count: 7, columns: 3) == 1)
        #expect(GridMove.next(from: 0, key: .left, count: 7, columns: 3) == 0)
    }
}

struct PanelSafetyTests {
    @Test func blocksAppCommandsInsidePanels() {
        #expect(PanelKeys.isAppCommand(keyCode: 12, modifiers: .command))
        #expect(PanelKeys.isAppCommand(keyCode: 13, modifiers: .command))
        #expect(!PanelKeys.isAppCommand(keyCode: 12, modifiers: [.command, .shift]))
        #expect(!PanelKeys.isAppCommand(keyCode: 0, modifiers: .command))
    }
}
