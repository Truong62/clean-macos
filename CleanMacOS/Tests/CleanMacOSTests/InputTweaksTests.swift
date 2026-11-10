import CoreGraphics
import Testing
@testable import CleanMacOS

struct ScrollTransformTests {
    private func scroll(_ settings: InputSettings, y: Double = 3, x: Double = 0, continuous: Bool = false, flags: CGEventFlags = []) -> ScrollResult {
        ScrollTransform.apply(ScrollInput(deltaY: y, deltaX: x, isContinuous: continuous, flags: flags), settings: settings)
    }

    @Test func leavesScrollingAloneByDefault() {
        #expect(scroll(InputSettings()) == .pass)
    }

    @Test func invertsWheelsButNeverTrackpads() {
        var settings = InputSettings()
        settings.invertVertical = true
        #expect(scroll(settings) == .scroll(deltaY: -3, deltaX: 0))
        #expect(scroll(settings, continuous: true) == .pass)
        settings.invertHorizontal = true
        #expect(scroll(settings, y: 0, x: 2) == .scroll(deltaY: 0, deltaX: -2))
    }

    @Test func shiftScrollsSidewaysAndOptionScrollsFaster() {
        var settings = InputSettings()
        settings.sidewaysModifier = .shift
        settings.fastModifier = .option
        settings.fastMultiplier = 4
        #expect(scroll(settings, flags: .maskShift) == .scroll(deltaY: 0, deltaX: 3))
        #expect(scroll(settings, flags: .maskAlternate) == .scroll(deltaY: 12, deltaX: 0))
    }

    @Test func linearScrollingUsesAFixedNumberOfLines() {
        var settings = InputSettings()
        settings.linearLines = 5
        #expect(scroll(settings, y: 1) == .scroll(deltaY: 5, deltaX: 0))
        #expect(scroll(settings, y: -7) == .scroll(deltaY: -5, deltaX: 0))
    }

    @Test func controlWheelZooms() {
        var settings = InputSettings()
        settings.zoomModifier = .control
        #expect(scroll(settings, y: 2, flags: .maskControl) == .zoom(zoomIn: true))
        #expect(scroll(settings, y: -1, flags: .maskControl) == .zoom(zoomIn: false))
        #expect(scroll(settings, y: 2) == .pass)
    }
}

struct InputGuardTests {
    @Test func dropsBouncedPressesOnly() {
        var debouncer = Debouncer(threshold: 0.03)
        #expect(!debouncer.shouldDrop(key: 1, isDown: true, at: 0))
        debouncer.record(key: 1, isDown: false, at: 0.10)
        #expect(debouncer.shouldDrop(key: 1, isDown: true, at: 0.12))
        #expect(!debouncer.shouldDrop(key: 1, isDown: true, at: 0.20))
        #expect(!debouncer.shouldDrop(key: 2, isDown: true, at: 0.11))
    }

    @Test func quitProtectionNeedsAHoldOrADoublePress() {
        var hold = QuitGuard(mode: .hold, hold: 0.8, window: 0.6)
        #expect(hold.keyDown(at: 0) == .wait)
        #expect(hold.keyUp(at: 0.3) == .cancel)
        #expect(hold.keyDown(at: 1) == .wait)
        #expect(hold.tick(at: 1.85) == .allow)

        var double = QuitGuard(mode: .doublePress, hold: 0.8, window: 0.6)
        #expect(double.keyDown(at: 0) == .remind)
        #expect(double.keyDown(at: 0.4) == .allow)
        #expect(double.keyDown(at: 2) == .remind)
        #expect(double.keyDown(at: 3) == .remind)
    }

    @Test func mapsMouseButtonsToActions() {
        var settings = InputSettings()
        settings.buttonActions = [3: .back, 4: .forward, 5: .missionControl]
        #expect(settings.action(forButton: 3) == .back)
        #expect(settings.action(forButton: 2) == nil)
        #expect(MouseButtonAction.back.keystroke == KeyStroke(keyCode: 33, flags: .maskCommand))
        #expect(MouseButtonAction.missionControl.keystroke == KeyStroke(keyCode: 126, flags: [.maskControl, .maskSecondaryFn]))
        #expect(MouseButtonAction.spaceRight.keystroke == KeyStroke(keyCode: 124, flags: [.maskControl, .maskSecondaryFn]))
    }

    @Test func listensOnlyForTheEventsItChanges() {
        var settings = InputSettings()
        #expect(settings.eventTypes.isEmpty)
        settings.invertVertical = true
        #expect(settings.eventTypes == [.scrollWheel])
        settings = InputSettings()
        settings.buttonActions = [3: .back]
        #expect(settings.eventTypes == [.otherMouseDown, .otherMouseUp])
        settings.quitProtection = .hold
        #expect(settings.eventTypes == [.otherMouseDown, .otherMouseUp, .keyDown, .keyUp])
        settings.focusFollowsMouse = true
        #expect(settings.eventTypes.last == .mouseMoved)
    }

    @Test func smoothScrollingEasesTowardsTheTarget() {
        var animator = SmoothScroll(response: 0.65)
        animator.add(40)
        let first = animator.step()
        #expect(abs(first - 26) < 0.001)
        #expect(abs(animator.remaining - 14) < 0.001)
        while animator.isActive { _ = animator.step() }
        #expect(abs(animator.remaining) < 0.5)
    }
}
