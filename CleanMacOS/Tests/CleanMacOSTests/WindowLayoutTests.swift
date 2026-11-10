import CoreGraphics
import Testing
@testable import CleanMacOS

struct WindowLayoutTests {
    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let window = CGRect(x: 100, y: 100, width: 600, height: 400)

    private func frame(_ action: WindowAction, gap: CGFloat = 0, current: CGRect? = nil) -> CGRect? {
        WindowGeometry.frame(for: action, screen: screen, window: current ?? window, gap: gap)
    }

    @Test func splitsTheVisibleScreen() {
        #expect(frame(.leftHalf) == CGRect(x: 0, y: 25, width: 720, height: 875))
        #expect(frame(.rightHalf) == CGRect(x: 720, y: 25, width: 720, height: 875))
        #expect(frame(.topHalf) == CGRect(x: 0, y: 25, width: 1440, height: 437.5))
        #expect(frame(.bottomRight) == CGRect(x: 720, y: 462.5, width: 720, height: 437.5))
        #expect(frame(.centerThird) == CGRect(x: 480, y: 25, width: 480, height: 875))
        #expect(frame(.lastTwoThirds) == CGRect(x: 480, y: 25, width: 960, height: 875))
        #expect(frame(.maximize) == screen)
        #expect(frame(.center) == CGRect(x: 420, y: 262.5, width: 600, height: 400))
    }

    @Test func leavesGapsBetweenWindowsAndEdges() {
        #expect(frame(.leftHalf, gap: 10) == CGRect(x: 10, y: 35, width: 705, height: 855))
        #expect(frame(.rightHalf, gap: 10) == CGRect(x: 725, y: 35, width: 705, height: 855))
        #expect(frame(.maximize, gap: 10) == CGRect(x: 10, y: 35, width: 1420, height: 855))
    }

    @Test func repeatingAHalfCyclesThroughSizes() {
        let half = frame(.leftHalf)!
        let twoThirds = WindowGeometry.cycled(.leftHalf, current: half, screen: screen, gap: 0)!
        #expect(twoThirds == CGRect(x: 0, y: 25, width: 960, height: 875))
        let third = WindowGeometry.cycled(.leftHalf, current: twoThirds, screen: screen, gap: 0)!
        #expect(third == CGRect(x: 0, y: 25, width: 480, height: 875))
        #expect(WindowGeometry.cycled(.leftHalf, current: third, screen: screen, gap: 0) == half)
        #expect(WindowGeometry.cycled(.maximize, current: screen, screen: screen, gap: 0) == screen)
    }

    @Test func usesVerticalThirdsOnPortraitScreens() {
        let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)
        #expect(WindowGeometry.frame(for: .firstThird, screen: portrait, window: window, gap: 0) == CGRect(x: 0, y: 0, width: 1080, height: 640))
    }

    @Test func movesWindowsToAnotherDisplayKeepingTheirPlace() {
        let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let moved = WindowGeometry.move(CGRect(x: 0, y: 25, width: 720, height: 875), from: screen, to: second)
        #expect(moved == CGRect(x: 1440, y: 0, width: 960, height: 1080))
    }

    @Test func picksTheScreenHoldingMostOfTheWindow() {
        let screens = [screen, CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        #expect(WindowGeometry.screenIndex(for: CGRect(x: 1300, y: 100, width: 600, height: 400), screens: screens) == 1)
        #expect(WindowGeometry.screenIndex(for: window, screens: screens) == 0)
    }

    @Test func snapsToTheEdgeTheCursorTouches() {
        #expect(WindowGeometry.snapAction(cursor: CGPoint(x: 1, y: 400), screen: screen) == .leftHalf)
        #expect(WindowGeometry.snapAction(cursor: CGPoint(x: 1439, y: 400), screen: screen) == .rightHalf)
        #expect(WindowGeometry.snapAction(cursor: CGPoint(x: 700, y: 26), screen: screen) == .maximize)
        #expect(WindowGeometry.snapAction(cursor: CGPoint(x: 2, y: 27), screen: screen) == .topLeft)
        #expect(WindowGeometry.snapAction(cursor: CGPoint(x: 1438, y: 898), screen: screen) == .bottomRight)
        #expect(WindowGeometry.snapAction(cursor: CGPoint(x: 700, y: 400), screen: screen) == nil)
    }
}
