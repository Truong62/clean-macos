import Foundation
import CoreGraphics
import Testing
@testable import CleanMacOS

struct SwitcherTests {
    private func window(_ id: Int, pid: Int32 = 10, title: String = "Document", app: String = "Editor") -> SwitcherWindow {
        SwitcherWindow(id: "\(id)", windowID: UInt32(id), pid: pid, bundleID: "app.\(pid)", appName: app, title: title,
                       frame: CGRect(x: 100, y: 100, width: 800, height: 600), zOrder: id)
    }

    private func filtered(_ windows: [SwitcherWindow], settings: SwitcherSettings = .init(), mode: SwitcherMode = .apps,
                          dock: Bool = false, display: CGRect? = nil) -> [SwitcherWindow] {
        SwitcherFilter.list(windows, settings: settings, mode: mode, frontPID: 10, display: display, history: .init(), focused: nil, dock: dock)
    }

    @Test func allFeaturesStartDisabled() {
        let value = SwitcherSettings()
        #expect(!value.isEnabled && !value.dockEnabled && !value.allWindowsEnabled && !value.takeover)
        #expect(!value.instantSelection && !value.ignoreHover && !value.pinSearch && !value.shortcutHints)
        #expect(!value.onePerApp && !value.minimalPreviews && !value.currentDesktopOnly && !value.currentDisplayOnly)
        #expect(!value.hideFullScreen && !value.hiddenAsMinimized && !value.dockCurrentDesktopOnly && !value.dockQuitsApp && !value.dockCreationOrder)
        #expect(value.windowless == .off)
        #expect(value.showDelay == 100 && value.dockDelay == 200 && value.dockOpacity == 100)
    }

    @Test func olderSettingsDecodeWithDefaults() throws {
        let old = Data(#"{"isEnabled":true,"layout":"Simple list","showDelay":250}"#.utf8)
        let settings = try JSONDecoder().decode(SwitcherSettings.self, from: old)
        #expect(settings.isEnabled)
        #expect(settings.layout == .list)
        #expect(settings.showDelay == 250)
        #expect(!settings.dockEnabled && !settings.takeover && !settings.allWindowsEnabled)
        #expect(settings.dockSize == .normal && settings.dockDelay == 200)
        #expect(try JSONDecoder().decode(SwitcherSettings.self, from: Data("{}".utf8)) == SwitcherSettings())
    }

    @Test func settingsRoundTripAndClampInvalidRanges() throws {
        var settings = SwitcherSettings()
        settings.dockEnabled = true
        settings.appRules = ["app.10": .never]
        settings.pausedApps = ["game.example", "/Applications/Game.app/Contents/MacOS/Game"]
        #expect(try JSONDecoder().decode(SwitcherSettings.self, from: JSONEncoder().encode(settings)) == settings)
        let clamped = try JSONDecoder().decode(SwitcherSettings.self, from: Data(#"{"showDelay":-10,"columns":99,"dockDelay":0,"dockOpacity":110}"#.utf8))
        #expect(clamped.showDelay == 0 && clamped.columns == 10 && clamped.dockDelay == 200 && clamped.dockOpacity == 100)
    }

    @Test func tinyTransparentAndExcludedWindowsAreRejected() {
        var tiny = window(1); tiny.frame.size = CGSize(width: 79, height: 59)
        var transparent = window(2); transparent.alpha = 0
        var excluded = window(3); excluded.excluded = true
        var overlay = window(4); overlay.layer = 3
        #expect(filtered([tiny, transparent, excluded, overlay, window(5)]).map(\.id) == ["5"])
        tiny.minimized = true
        transparent.hidden = true
        #expect(filtered([tiny, transparent]).count == 2)
    }

    @Test func unconfirmedGhostsAreDroppedWithExceptions() {
        var ghost = window(1); ghost.axKnown = false
        #expect(filtered([ghost]).isEmpty)
        ghost.axAnswered = false
        #expect(filtered([ghost]).count == 1)
        ghost.axAnswered = true; ghost.otherDesktop = true
        #expect(filtered([ghost]).count == 1)
        var helper = window(2, title: ""); helper.axKnown = false; helper.axAnswered = false; helper.isOnScreen = false
        #expect(filtered([helper]).isEmpty)
    }

    @Test func minimizedAndDesktopPolicies() {
        var a = window(1); a.minimized = true
        var b = window(2); b.hidden = true
        var c = window(3); c.otherDesktop = true; c.fullScreen = true
        var d = window(4); d.otherDesktop = true
        var settings = SwitcherSettings()
        settings.minimized = .last; settings.hiddenAsMinimized = true
        #expect(filtered([a, b, c, d], settings: settings).map(\.id) == ["3", "4", "1", "2"])
        settings.minimized = .hide; settings.currentDesktopOnly = true
        #expect(filtered([a, b, c, d], settings: settings).map(\.id) == ["3"])
        settings.hideFullScreen = true
        #expect(filtered([a, b, c, d], settings: settings).isEmpty)
    }

    @Test func displayFilterAndCurrentApp() {
        let a = window(1)
        var b = window(2, pid: 11); b.frame.origin.x = 2000
        var settings = SwitcherSettings(); settings.currentDisplayOnly = true
        #expect(filtered([a, b], settings: settings, display: CGRect(x: 0, y: 0, width: 1920, height: 1080)).map(\.id) == ["1"])
        #expect(filtered([a, b], mode: .currentApp).map(\.id) == ["1"])
    }

    @Test func windowlessRulesAndTakeover() {
        let empty = SwitcherWindow(id: "app", windowID: nil, pid: 11, bundleID: "com.apple.finder", appName: "Finder", title: "", frame: .zero)
        #expect(filtered([empty]).isEmpty)
        var settings = SwitcherSettings(); settings.windowless = .finder
        #expect(filtered([empty], settings: settings).count == 1)
        #expect(filtered([empty], settings: settings, mode: .allWindows).isEmpty)
        settings.windowless = .off; settings.takeover = true
        #expect(filtered([empty], settings: settings).count == 1)
        settings.appRules[empty.bundleID] = .never
        #expect(filtered([empty], settings: settings).isEmpty)
        settings.appRules[empty.bundleID] = .show; settings.takeover = false
        #expect(filtered([empty], settings: settings).count == 1)
    }

    @Test func capKeepsToggleAndOnePerAppBeforeExtraWindows() {
        let entries = (1...70).map { window($0, pid: $0 < 60 ? 10 : Int32($0)) }
        let result = filtered(entries)
        #expect(result.count == 48)
        #expect(result.prefix(2).map(\.id) == ["1", "2"])
        #expect(Set(result.map(\.pid)) == Set(entries.map(\.pid)))
    }

    @Test func perAppCollapseDoesNotAffectAllWindowsOrDock() {
        var settings = SwitcherSettings(); settings.onePerApp = true
        let entries = [window(1), window(2), window(3, pid: 11)]
        #expect(filtered(entries, settings: settings).count == 2)
        #expect(filtered(entries, settings: settings, mode: .allWindows).count == 3)
        #expect(filtered(entries, settings: settings, dock: true).count == 3)
    }

    @Test func dockIgnoresSwitcherRulesAndCapsBeforeCreationSort() {
        var settings = SwitcherSettings(); settings.appRules["app.10"] = .never; settings.minimized = .hide; settings.dockCreationOrder = true
        var entries = (1...20).map { window($0) }
        for index in entries.indices { entries[index].zOrder = 20 - index; entries[index].minimized = true }
        #expect(filtered(entries, settings: settings, dock: true).map(\.windowID) == (9...20).map { Optional(UInt32($0)) })
        entries[0].fullScreen = true
        settings.dockCurrentDesktopOnly = true
        #expect(!filtered([entries[0]], settings: settings, dock: true).contains { $0.id == "1" })
    }

    @Test func recentHistoryTogglesAndPrunes() {
        var history = SwitcherHistory()
        history.focus("1", pid: 10)
        history.focus("3", pid: 11, source: "1")
        let entries = [window(1), window(2), window(3, pid: 11)]
        #expect(history.ordered(entries, focused: nil).map(\.id) == ["3", "1", "2"])
        #expect(history.ordered(entries, focused: "2").first?.id == "2")
        history.prune(ids: ["1"], pids: [10])
        #expect(history.windows == ["1"] && history.apps == [10])
    }

    @Test func historyIsBounded() {
        var history = SwitcherHistory()
        for index in 0..<300 { history.focus(String(index), pid: Int32(index)) }
        #expect(history.windows.count == 256 && history.apps.count == 256)
        #expect(history.windows.first == "299")
    }

    @Test func tokenSearchFoldsCaseAndDiacritics() {
        let entries = [window(1, title: "Café notes", app: "Éditeur"), window(2, title: "Other")]
        #expect(SwitcherFilter.search(entries, query: "  CAFE\t editeur  ").map(\.id) == ["1"])
        #expect(SwitcherFilter.search(entries, query: "cafe missing").isEmpty)
        #expect(SwitcherFilter.search(entries, query: " \n").count == 2)
    }

    @Test func pendingPressesAndReleaseCommitOnArrival() {
        var session = SwitcherSession()
        session.begin(reverse: false)
        session.step(2)
        #expect(session.release() == false)
        #expect(session.phase == .commitWhenReady)
        #expect(session.arrive((1...5).map { window($0) }, frontPID: 10, grouped: false) == true)
        #expect(session.selected?.id == "4")
    }

    @Test func pendingPressesAreBounded() {
        var session = SwitcherSession(); session.begin(reverse: false)
        session.step(1000); #expect(session.pendingSteps == 64)
        session.step(-1000); #expect(session.pendingSteps == -64)
        session.cancel()
        #expect(session.arrive([window(1)], frontPID: 10, grouped: false) == false)
        #expect(session.entries.isEmpty)
    }

    @Test func reverseAndGroupedInitialSelection() {
        let entries = [window(1), window(2), window(3, pid: 11)]
        var session = SwitcherSession(); session.begin(reverse: true)
        _ = session.arrive(entries, frontPID: 10, grouped: false)
        #expect(session.selected?.id == "3")
        session.begin(reverse: false)
        _ = session.arrive(entries, frontPID: 10, grouped: true)
        #expect(session.selected?.id == "3")
    }

    @Test func freshPressWrapsAndRepeatStopsAtEdges() {
        var session = SwitcherSession(); session.begin(reverse: false)
        _ = session.arrive([window(1), window(2), window(3)], frontPID: 10, grouped: false)
        session.step(10, repeating: true); #expect(session.selection == 2)
        session.step(1); #expect(session.selection == 0)
        session.step(-1); #expect(session.selection == 2)
        session.step(-10, repeating: true); #expect(session.selection == 0)
    }

    @Test func verticalMovementClampsShortRowWithoutWrapping() {
        var session = SwitcherSession(); session.begin(reverse: false)
        _ = session.arrive((1...7).map { window($0) }, frontPID: 10, grouped: false)
        session.selection = 3
        session.row(1, columns: 4); #expect(session.selection == 6)
        session.row(1, columns: 4); #expect(session.selection == 6)
        session.row(-1, columns: 4); #expect(session.selection == 2)
        session.row(-1, columns: 4); #expect(session.selection == 2)
    }

    @Test func searchPreservesSelectionAndLimitsLength() {
        var session = SwitcherSession(); session.begin(reverse: false)
        _ = session.arrive([window(1, title: "Apple"), window(2, title: "Banana"), window(3, title: "Banana pie")], frontPID: 10, grouped: false)
        session.search("banana"); #expect(session.selected?.id == "2")
        session.search("pie"); #expect(session.selected?.id == "3")
        session.search(String(repeating: "x", count: 100)); #expect(session.query.count == 64 && session.selected == nil)
        session.pinned = true; #expect(session.release() == false)
    }

    @Test func replacingClosedWindowSelectsReplacement() {
        var session = SwitcherSession(); session.begin(reverse: false)
        _ = session.arrive([window(1), window(2), window(3)], frontPID: 10, grouped: false)
        session.replace([window(1), window(3)])
        #expect(session.selected?.id == "3")
        session.replace([])
        #expect(session.selection == 0 && session.selected == nil)
    }

    @Test(arguments: [9, 10]) func gridBalancesRows(count: Int) {
        let grid = SwitcherGrid.make(count: count, layout: .previews, scale: 1, cap: 0, screen: CGSize(width: 1920, height: 1080))
        #expect(grid.columns == 5)
        #expect(grid.card == CGSize(width: 288, height: 214))
        #expect(grid.panel.width <= 1920 * 0.92 && grid.panel.height <= 1080 * 0.85)
    }

    @Test(arguments: SwitcherLayout.allCases) func allLayoutsRespectScreenAndColumnCap(layout: SwitcherLayout) {
        let grid = SwitcherGrid.make(count: 48, layout: layout, scale: 1.8, cap: 2, screen: CGSize(width: 1000, height: 700))
        #expect(grid.columns <= 2 && grid.columns >= 1)
        #expect(grid.panel.width <= 920 && grid.panel.height <= 595)
    }

    @Test func emptyAndTinyGridGeometryIsFinite() {
        let grid = SwitcherGrid.make(count: 0, layout: .previews, scale: 1, cap: 0, screen: CGSize(width: 200, height: 100))
        #expect(grid.columns == 1 && grid.panel.width > 0 && grid.panel.height > 0)
    }

    @Test(arguments: DockEdge.allCases, [false, true]) func dockBandAndHitTesting(edge: DockEdge, hidden: Bool) {
        let geometry = DockGeometry(edge: edge, autoHide: hidden)
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let point = edge == .bottom ? CGPoint(x: -960, y: 1070) : CGPoint(x: edge == .left ? -1910 : -10, y: 540)
        #expect(geometry.inBand(point, screen: screen))
        #expect(!geometry.inBand(CGPoint(x: -960, y: 540), screen: screen))
        #expect(geometry.hit(point, dockWindows: [], dockOwnsElement: true))
        #expect(!geometry.hit(point, dockWindows: [], dockOwnsElement: false))
        #expect(geometry.hit(point, dockWindows: [CGRect(x: point.x + 7, y: point.y, width: 30, height: 30)], dockOwnsElement: false))
    }

    @Test(arguments: DockEdge.allCases, [false, true]) func dockPlacementFitsAndFacesIcon(edge: DockEdge, hidden: Bool) {
        let geometry = DockGeometry(edge: edge, autoHide: hidden)
        let visible = CGRect(x: -1200, y: 20, width: 1200, height: 800)
        let icon = CGRect(x: edge == .left ? -1190 : edge == .right ? -74 : -640, y: edge == .bottom ? 740 : 380, width: 64, height: 64)
        let rect = geometry.placement(icon: icon, panel: CGSize(width: 250, height: 211), visible: visible)
        #expect(visible.insetBy(dx: 8, dy: 8).contains(rect))
        if edge == .bottom { #expect(rect.maxY == icon.minY - (hidden ? 0 : 6)) }
        if edge == .left { #expect(rect.minX == icon.maxX + (hidden ? 0 : 6)) }
        if edge == .right { #expect(rect.maxX == icon.minX - (hidden ? 0 : 6)) }
    }

    @Test func dockSizesAndOpeningBridge() {
        let geometry = DockGeometry()
        #expect(geometry.panelSize(count: 1, size: .normal, screen: CGSize(width: 1920, height: 1080)) == CGSize(width: 250, height: 211))
        let icon = CGRect(x: 500, y: 900, width: 64, height: 64)
        let panel = CGRect(x: 400, y: 600, width: 300, height: 200)
        #expect(geometry.inOpeningPath(CGPoint(x: 532, y: 850), icon: icon, panel: panel))
        #expect(!geometry.inOpeningPath(CGPoint(x: 800, y: 850), icon: icon, panel: panel))
    }

    @Test func dockHoverPreservesTimerWithinToleranceAndRechecksTarget() {
        var state = DockHoverState()
        state.hover(pid: 10, point: .zero, now: 1, delay: 0.2)
        state.hover(pid: 10, point: CGPoint(x: 3, y: 4), now: 1.1, delay: 0.2)
        #expect(state.deadline == 1.2)
        #expect(state.open(now: 1.3, confirmedPID: 11) == false)
        #expect(state.open(now: 1.3, confirmedPID: 10) == true)
        state.hover(pid: 11, point: .zero, now: 2, delay: 0.9)
        #expect(state.deadline == 2.1)
        state.hover(pid: nil, point: .zero, now: 2.05, delay: 0)
        #expect(state.deadline == nil)
        state.close(); #expect(state.visiblePID == nil)
    }

    @Test func cacheEvictsLeastRecentlyUsedAndBoundsBytes() {
        var cache = ThumbnailPolicy()
        for id in 0..<48 { _ = cache.insert(String(id), bytes: 100, now: Double(id)) }
        cache.touch("0", now: 100)
        #expect((cache.insert("48", bytes: 100, now: 101) == ["1"]))
        #expect(cache.entries.count == 48)
        _ = cache.insert("huge", bytes: 65 * 1024 * 1024, now: 102)
        #expect(cache.bytes <= 64 * 1024 * 1024)
        #expect(cache.entries.isEmpty)
    }

    @Test func cachePruningAndMemoryPressureClear() {
        var cache = ThumbnailPolicy()
        _ = cache.insert("1", bytes: 100, now: 0); _ = cache.insert("2", bytes: 100, now: 1)
        cache.prune(["2"]); #expect(Set(cache.entries.keys) == ["2"])
        cache.clear(); #expect(cache.bytes == 0)
    }

    @Test func healthThrottleBacksOffAndPermissionChecksAreSpaced() {
        var cache = ThumbnailPolicy()
        #expect(cache.preflight(now: 0) == true)
        #expect(cache.preflight(now: 4.9) == false)
        #expect(cache.preflight(now: 5) == true)
        cache.health(duration: 0.5, permissionCheck: true, now: 5)
        #expect(cache.pausedUntil == 35 && cache.backoff == 60)
        #expect(!cache.canCapture(now: 34, permission: true, active: true, simple: false, pausedApp: false))
        #expect(cache.canCapture(now: 35, permission: true, active: true, simple: false, pausedApp: false))
        for index in 0..<10 { cache.health(duration: 2, permissionCheck: false, now: Double(index) * 1000) }
        #expect(cache.backoff == 600)
    }

    @Test func captureRequiresPermissionActiveSessionAndPreviewLayout() {
        let cache = ThumbnailPolicy()
        #expect(!cache.canCapture(now: 0, permission: false, active: true, simple: false, pausedApp: false))
        #expect(!cache.canCapture(now: 0, permission: true, active: false, simple: false, pausedApp: false))
        #expect(!cache.canCapture(now: 0, permission: true, active: true, simple: true, pausedApp: false))
        #expect(!cache.canCapture(now: 0, permission: true, active: true, simple: false, pausedApp: true))
    }

    @Test func scrollAccumulatesResetsAndIgnoresMomentum() {
        var scroll = SwitcherScroll()
        #expect((scroll.steps(x: 0, y: -20, continuous: true, momentum: false, now: 0) == 0))
        #expect((scroll.steps(x: 0, y: -15, continuous: true, momentum: false, now: 0.1) == 1))
        #expect((scroll.steps(x: 0, y: 100, continuous: true, momentum: true, now: 0.2) == 0))
        #expect((scroll.steps(x: 0, y: 20, continuous: true, momentum: false, now: 0.2) == 0))
        #expect((scroll.steps(x: 0, y: 20, continuous: true, momentum: false, now: 0.5) == 0))
        #expect((scroll.steps(x: -10, y: 2, continuous: false, momentum: false, now: 0.6) == 1))
    }

    @Test func shortcutsRequireExactModifiersAndShiftReverses() {
        let trigger = SwitcherTrigger(mode: .apps, key: 48, modifiers: .maskCommand)
        #expect(trigger.match(key: 48, flags: .maskCommand, character: "\t") == false)
        #expect(trigger.match(key: 48, flags: [.maskCommand, .maskShift], character: "\t") == true)
        #expect(trigger.match(key: 48, flags: [.maskCommand, .maskAlternate], character: "\t") == nil)
        #expect(trigger.match(key: 49, flags: .maskCommand, character: " ") == nil)
    }

    @Test func windowShortcutMatchesMovedBacktickWithoutReversing() {
        let trigger = SwitcherTrigger(mode: .currentApp, key: 50, modifiers: .maskCommand)
        #expect(trigger.match(key: 99, flags: [.maskCommand, .maskAlternate, .maskShift], character: "~") == false)
        #expect(trigger.match(key: 99, flags: [.maskCommand, .maskControl], character: "`") == nil)
    }

    @Test func takeoverOnlyTouchesLiveEnabledMatchingIDs() {
        let triggers = [SwitcherTrigger(mode: .apps, key: 48, modifiers: .maskCommand)]
        let keys = [SwitcherHotKey(id: 1, key: 48, modifiers: UInt32(CGEventFlags.maskCommand.rawValue), enabled: true),
                    SwitcherHotKey(id: 2, key: 48, modifiers: UInt32(CGEventFlags.maskCommand.union(.maskShift).rawValue), enabled: false),
                    SwitcherHotKey(id: 27, key: 50, modifiers: UInt32(CGEventFlags.maskCommand.rawValue), enabled: true),
                    SwitcherHotKey(id: 99, key: 48, modifiers: UInt32(CGEventFlags.maskCommand.rawValue), enabled: true)]
        #expect(SwitcherTakeoverPlan.desired(keys, triggers: triggers, permitted: true) == [1])
        #expect(SwitcherTakeoverPlan.desired(keys, triggers: triggers, permitted: false).isEmpty)
    }
    @Test func pinnedSelectionWrapsAndSurvivesRefresh() {
        var selection = PinnedPreviewSelection()
        selection.update(["1", "2", "3"])
        selection.step(-1); #expect(selection.selected == "3")
        selection.update(["2", "3"]); #expect(selection.selected == "3")
        selection.update(["2"]); #expect(selection.selected == "2")
        selection.update([]); selection.step(1); #expect(selection.selected == nil)
    }

    @Test func dragClampsToTargetDisplayWithoutResizing() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let visible = CGRect(x: -1920, y: 20, width: 1920, height: 1040)
        let frame = PreviewDragGeometry.placed(window: window, pointer: CGPoint(x: -10, y: 1050), visible: visible)
        #expect(frame.size == window.size)
        #expect(visible.contains(frame))
        #expect(frame.maxX == visible.maxX && frame.maxY == visible.maxY)
        let oversized = PreviewDragGeometry.placed(window: CGRect(x: 0, y: 0, width: 4000, height: 2000), pointer: .zero, visible: visible)
        #expect(oversized.origin == visible.origin && oversized.width == 4000)
    }

    @Test func marqueeWaitsThenMovesAtSpecifiedRate() {
        #expect(MarqueeMotion.offset(elapsed: 0.4, width: 200) == 0)
        #expect(abs(MarqueeMotion.offset(elapsed: 1.4, width: 200) - 26) < 0.001)
        #expect(MarqueeMotion.offset(elapsed: 100, width: 0) == 0)
        #expect(MarqueeMotion.offset(elapsed: 20, width: 200) < 220)
    }

    @Test func recordersOnlyAcceptRoleSpecificCombinations() {
        #expect(SwitcherTrigger.allowed(mode: .apps, key: 48, flags: .maskCommand))
        #expect(SwitcherTrigger.allowed(mode: .currentApp, key: 50, flags: [.maskCommand, .maskShift]))
        #expect(SwitcherTrigger.allowed(mode: .allWindows, key: 48, flags: .maskAlternate))
        #expect(!SwitcherTrigger.allowed(mode: .apps, key: 49, flags: .maskCommand))
        #expect(!SwitcherTrigger.allowed(mode: .currentApp, key: 50, flags: [.maskCommand, .maskControl]))
    }

    @Test func dockInstancesFollowTilesWhenReorderedAndPruneQuitProcesses() {
        var mapping = DockInstanceAssignments()
        let initial = mapping.resolve(tiles: ["left", "right"], processes: [10, 20])
        #expect(initial == ["left": 10, "right": 20])
        let dragged = mapping.resolve(tiles: ["right", "left"], processes: [10, 20])
        #expect(dragged == initial)
        let terminated = mapping.resolve(tiles: ["right", "left"], processes: [20])
        #expect(terminated == ["right": 20])
        let stale = mapping.resolve(tiles: ["right"], processes: [])
        #expect(stale.isEmpty)
    }

}
