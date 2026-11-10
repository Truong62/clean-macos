import Foundation
import Testing
@testable import CleanMacOS

struct IslandInteractionTests {
    @Test func capsuleHotZoneExcludesTransparentCornersAndOtherDisplays() {
        let zone = IslandHotZone(frame: CGRect(x: -800, y: 880, width: 100, height: 20), capsule: true)
        #expect(zone.contains(CGPoint(x: -750, y: 890)))
        #expect(!zone.contains(CGPoint(x: -800, y: 880)))
        #expect(!zone.contains(CGPoint(x: 750, y: 890)))
        #expect(!zone.contains(CGPoint(x: -750, y: 879)))
    }

    @Test func notchHotZoneIncludesNeckAndBodyButNotShoulders() {
        let zone = IslandHotZone(frame: CGRect(x: 100, y: 500, width: 500, height: 300), capsule: false, neckWidth: 180, neckHeight: 32)
        #expect(zone.contains(CGPoint(x: 350, y: 790)))
        #expect(zone.contains(CGPoint(x: 150, y: 700)))
        #expect(!zone.contains(CGPoint(x: 150, y: 790)))
        #expect(!zone.contains(CGPoint(x: 99, y: 700)))
    }

    @Test func repeatedLocalAndGlobalMovesOnlyChangeAtBoundaries() {
        var pointer = IslandPointerTracking()
        for _ in 0..<1000 { #expect(pointer.update(inside: false, hiddenTrigger: false) == false) }
        #expect(pointer.update(inside: true, hiddenTrigger: false) == true)
        for _ in 0..<1000 { #expect(pointer.update(inside: true, hiddenTrigger: false) == false) }
        #expect(pointer.update(inside: false, hiddenTrigger: false) == true)
        #expect(pointer.update(inside: false, hiddenTrigger: false) == false)
    }

    @Test func hiddenActivationHasIndependentEntryAndExit() {
        var pointer = IslandPointerTracking()
        #expect(pointer.update(inside: false, hiddenTrigger: true) == true)
        #expect(pointer.hiddenTrigger)
        #expect(pointer.update(inside: false, hiddenTrigger: true) == false)
        #expect(pointer.update(inside: true, hiddenTrigger: true) == true)
        #expect(pointer.update(inside: false, hiddenTrigger: false) == true)
        #expect(!pointer.hiddenTrigger)
    }

    @Test func burstOfLayoutRequestsSchedulesOnlyOneFrame() {
        var coalescer = IslandLayoutCoalescer(interval: 0.02)
        #expect(coalescer.request(at: 10) == 0)
        for _ in 0..<1000 { #expect(coalescer.request(at: 10.001) == nil) }
        coalescer.finish(at: 10.005)
        let delay = coalescer.request(at: 10.006) ?? -1
        #expect(abs(delay - 0.019) < 0.000001)
        #expect(coalescer.request(at: 10.01) == nil)
        coalescer.finish(at: 10.025)
        #expect(coalescer.request(at: 11) == 0)
    }

    @Test func cancellationAllowsFutureRequestsAndKeepsFrameLimit() {
        var coalescer = IslandLayoutCoalescer(interval: 0.02)
        #expect(coalescer.request(at: .nan) == nil)
        #expect(!coalescer.pending)
        #expect(coalescer.request(at: 1) == 0)
        coalescer.finish(at: 1)
        #expect(coalescer.request(at: 1.005) != nil)
        coalescer.cancel()
        #expect(!coalescer.pending)
        #expect(abs((coalescer.request(at: 1.01) ?? -1) - 0.01) < 0.000001)
    }

    @Test func continuousMovesCannotExceedFrameRate() {
        var coalescer = IslandLayoutCoalescer(interval: 1 / 60)
        var scheduled: Double?
        var layouts: [Double] = []
        for index in 0..<1000 {
            let time = Double(index) / 1000
            if let deadline = scheduled, time >= deadline {
                coalescer.finish(at: time)
                layouts.append(time)
                scheduled = nil
            }
            if let delay = coalescer.request(at: time) { scheduled = time + delay }
        }
        #expect(layouts.count <= 60)
        #expect(layouts.count >= 58)
        for (first, second) in zip(layouts, layouts.dropFirst()) {
            #expect(second - first >= 1 / 60 - 0.000001)
        }
    }

    @Test func outsideClickOnlyDismissesAnOpenIslandBelowTheMenu() {
        #expect(IslandDismissal.shouldClose(open: true, insidePanel: false, insideCopy: false, belowMenu: true))
        #expect(!IslandDismissal.shouldClose(open: false, insidePanel: false, insideCopy: false, belowMenu: true))
        #expect(!IslandDismissal.shouldClose(open: true, insidePanel: true, insideCopy: false, belowMenu: true))
        #expect(!IslandDismissal.shouldClose(open: true, insidePanel: false, insideCopy: true, belowMenu: true))
        #expect(!IslandDismissal.shouldClose(open: true, insidePanel: false, insideCopy: false, belowMenu: false))
    }

    @Test func unchangedLayoutDoesNotRequireWindowUpdates() {
        let layout = IslandPanelLayout(frame: CGRect(x: 100, y: 200, width: 100, height: 20), keyboard: false, ignoresMouse: true, alpha: 1, level: 25, captures: false)
        var next = layout
        #expect(next == layout)
        next.ignoresMouse = false
        #expect(next != layout)
        next = layout
        next.frame.size.height = 300
        #expect(next != layout)
        next = layout
        next.keyboard = true
        #expect(next != layout)
    }
}
