import CoreGraphics
import Foundation
import Testing
@testable import CleanMacOS

struct RadialMigrationTests {
    @Test func migratesEveryLegacyFieldAndPreservesSliceIdentity() throws {
        let data = Data("""
        {"isEnabled":true,"mode":"hold","opensAtPointer":false,"mouseButton":31,
         "slices":[{"id":"12345678-1234-1234-1234-123456789ABC","title":"Old action","symbol":"star","action":{"command":{"_0":"clipboardHistory"}}}]}
        """.utf8)
        let settings = try JSONDecoder().decode(RadialSettings.self, from: data)
        #expect(settings.isEnabled)
        #expect(settings.mode == .hold)
        #expect(!settings.opensAtPointer)
        #expect(settings.wheels.count == 1)
        let wheel = try #require(settings.wheels.first)
        #expect(wheel.id == RadialWheel.originalID)
        #expect(wheel.keyboardEnabled)
        #expect(wheel.mouseButton == 31)
        #expect(wheel.slices.first?.id.uuidString == "12345678-1234-1234-1234-123456789ABC")
        #expect(wheel.slices.first?.action == .command("clipboardHistory"))
        #expect(try JSONDecoder().decode(RadialSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func disabledLegacySettingsStayDisabled() throws {
        let settings = try JSONDecoder().decode(RadialSettings.self, from: Data("{\"isEnabled\":false,\"slices\":[]}".utf8))
        #expect(!settings.isEnabled)
        #expect(!settings.wheels[0].keyboardEnabled)
        #expect(settings.wheels[0].slices.isEmpty)
    }

    @Test func missingFieldsUseDefaults() throws {
        let settings = try JSONDecoder().decode(RadialSettings.self, from: Data("{}".utf8))
        #expect(settings == RadialSettings())
        let wheel = try JSONDecoder().decode(RadialWheel.self, from: Data("{\"name\":\"Custom\"}".utf8))
        #expect(wheel.name == "Custom")
        #expect(wheel.accent == .blue)
        #expect(!wheel.keyboardEnabled)
        #expect(wheel.mouseButton == nil)
        #expect(wheel.slices.isEmpty)
    }

    @Test func keepsAnExplicitlyEmptyWheelList() throws {
        let settings = try JSONDecoder().decode(RadialSettings.self, from: Data("{\"wheels\":[],\"slices\":[]}".utf8))
        #expect(settings.wheels.isEmpty)
    }

    @Test func wheelsTakePrecedenceOverLegacyFields() throws {
        let settings = try JSONDecoder().decode(RadialSettings.self, from: Data("{\"wheels\":[{\"name\":\"New\"}],\"mouseButton\":4}".utf8))
        #expect(settings.wheels[0].name == "New")
        #expect(settings.wheels[0].mouseButton == nil)
    }

    @Test func allPresetsStartWithTriggersOff() {
        #expect(RadialAccent.allCases.count == 12)
        #expect(RadialSettings.Preset.allCases.count == 6)
        #expect(!RadialSettings().isEnabled)
        for preset in RadialSettings.Preset.allCases {
            let wheel = preset.wheel()
            #expect(!wheel.keyboardEnabled)
            #expect(wheel.mouseButton == nil)
            #expect(wheel.slices.count <= 12)
            #expect(wheel.slices.isEmpty == (preset == .blank))
        }
        #expect(RadialSettings.general.map(\.action) == [.media(16), .media(17), .command("grabText"), .folder("~/Downloads"), .command("pickColor"), .media(18)])
    }

    @Test func presetInstancesHaveIndependentIdentities() {
        let first = RadialSettings.Preset.general.wheel()
        let second = RadialSettings.Preset.general.wheel()
        #expect(first.id != second.id)
        #expect(Set(first.slices.map(\.id)).isDisjoint(with: Set(second.slices.map(\.id))))
    }

    @Test func roundTripsEveryActionAndWheelSetting() throws {
        var settings = RadialSettings()
        settings.wheels = RadialAccent.allCases.map { accent in
            RadialWheel(name: accent.rawValue, accent: accent, keyboardEnabled: true, mouseButton: 3, slices: [
                RadialSlice(title: "App", symbol: "app", action: .app("/tmp/Fixture.app")),
                RadialSlice(title: "File", symbol: "doc", action: .folder("/tmp/file")),
                RadialSlice(title: "Link", symbol: "link", action: .link("https://example.com")),
                RadialSlice(title: "Key", symbol: "keyboard", action: .keystroke(RadialKeystroke(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue))),
                RadialSlice(title: "Toggle", symbol: "circle", action: .toggle("darkMode")),
                RadialSlice(title: "Window", symbol: "macwindow", action: .window(.leftHalf)),
                RadialSlice(title: "Child", symbol: "folder", action: .submenu(RadialSettings.media)),
            ])
        }
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(RadialSettings.self, from: data) == settings)
    }

    @Test(arguments: [0, 1, 2, 32, -1]) func rejectsInvalidMouseButtons(_ button: Int) {
        #expect(RadialWheel(mouseButton: button).mouseButton == nil)
    }

    @Test(arguments: [3, 4, 15, 31]) func acceptsAllSupportedMouseButtons(_ button: Int) {
        #expect(RadialWheel(mouseButton: button).mouseButton == button)
    }

    @Test func repairsDuplicateWheelIDs() throws {
        let data = Data("""
        {"wheels":[{"id":"00000000-0000-0000-0000-000000000001"},{"id":"00000000-0000-0000-0000-000000000001"}]}
        """.utf8)
        let settings = try JSONDecoder().decode(RadialSettings.self, from: data)
        #expect(Set(settings.wheels.map(\.id)).count == 2)
        #expect(settings.wheels[0].id == RadialWheel.originalID)
    }
}

struct RadialAvailabilityTests {
    private func slice(_ action: RadialSlice.Action) -> RadialSlice { RadialSlice(title: "Fixture", symbol: "star", action: action) }

    @Test func filtersPathsUsingTemporaryFixtures() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".radial-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("file.txt")
        try Data("fixture".utf8).write(to: file)
        let app = folder.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let slices = [slice(.app(app.path)), slice(.folder(file.path)), slice(.folder(folder.path)),
                      slice(.app(folder.appendingPathComponent("Missing.app").path)), slice(.folder(folder.appendingPathComponent("missing").path))]
        let visible = RadialAvailability.visible(slices) { action in
            RadialAvailability.canRun(action, commandIDs: [], toggleIDs: [], hasWindow: false,
                                      pathExists: { FileManager.default.fileExists(atPath: $0) })
        }
        #expect(visible.map(\.id) == Array(slices.prefix(3)).map(\.id))
    }

    @Test func validatesActionAvailability() {
        func available(_ action: RadialSlice.Action) -> Bool {
            RadialAvailability.canRun(action, commandIDs: ["grabText", "page.tools"], toggleIDs: ["darkMode"], hasWindow: false, pathExists: { _ in false })
        }
        #expect(available(.command("page.tools")))
        #expect(!available(.command("missing")))
        #expect(available(.toggle("darkMode")))
        #expect(!available(.toggle("grabText")))
        #expect(available(.link("https://example.com")))
        #expect(available(.link("mailto:user@example.com")))
        #expect(!available(.link("example.com")))
        #expect(!available(.link("https://exa mple.com")))
        #expect(!available(.window(.maximize)))
        #expect(available(.media(16)))
        #expect(!available(.media(999)))
        #expect(available(.keystroke(RadialKeystroke(keyCode: 9))))
        #expect(!available(.keystroke(RadialKeystroke(keyCode: 128))))
        #expect(!available(.keystroke(RadialKeystroke(modifiers: UInt64.max))))
    }

    @Test func removesEmptySubmenusAndUnrunnableChildren() {
        let runnable = slice(.media(16))
        let missing = slice(.command("missing"))
        let parent = slice(.submenu([missing, runnable]))
        let empty = slice(.submenu([missing]))
        let result = RadialAvailability.visible([missing, parent, empty]) { $0 == .media(16) }
        #expect(result.count == 1)
        #expect(result.first?.id == parent.id)
        #expect(result.first?.action == .submenu([runnable]))
        #expect(RadialAvailability.visible([empty, missing]) { _ in false }.isEmpty)
    }

    @Test func limitsEachLevelAndStripsDeeperSubmenus() {
        let leaf = slice(.media(16))
        let nested = slice(.submenu([leaf]))
        let parent = slice(.submenu([nested] + Array(repeating: leaf, count: 20)))
        let result = RadialAvailability.limited([parent] + Array(repeating: leaf, count: 20))
        #expect(result.count == 12)
        if case .submenu(let children) = result[0].action {
            #expect(children.count <= 12)
            #expect(children.allSatisfy { $0.action == .media(16) })
        } else { Issue.record("Expected submenu") }
    }
}

struct RadialNavigationTests {
    private let leaf = RadialSlice(title: "Play", symbol: "play", action: .media(16))

    @Test func submenuBackAndClose() {
        var navigation = RadialNavigation()
        let parent = RadialSlice(title: "Media", symbol: "music.note", action: .submenu([leaf]))
        let opened = navigation.open([parent, leaf])
        #expect(opened)
        #expect(navigation.select(0) == nil)
        #expect(navigation.isOpen)
        #expect(navigation.submenu?.id == parent.id)
        #expect(navigation.slices == [leaf])
        navigation.back()
        #expect(navigation.isOpen)
        #expect(navigation.submenu == nil)
        #expect(navigation.slices == [parent, leaf])
        navigation.back()
        #expect(!navigation.isOpen)
        #expect(navigation.slices.isEmpty)
    }

    @Test func selectingLeafClosesAndReturnsOnlyItsAction() {
        var navigation = RadialNavigation()
        navigation.open([RadialSlice(title: "Media", symbol: "music.note", action: .submenu([leaf]))])
        #expect(navigation.select(0) == nil)
        #expect(navigation.select(0) == .media(16))
        #expect(!navigation.isOpen)
        #expect(navigation.select(0) == nil)
    }

    @Test func invalidSelectionsAndEmptyWheelsAreSafe() {
        var navigation = RadialNavigation()
        let opened = navigation.open([])
        #expect(!opened)
        #expect(navigation.select(0) == nil)
        navigation.open([leaf])
        #expect(navigation.select(-1) == nil)
        #expect(navigation.select(1) == nil)
        #expect(navigation.isOpen)
        navigation.close()
        navigation.back()
        #expect(!navigation.isOpen)
    }

    @Test func reopeningResetsSubmenu() {
        var navigation = RadialNavigation()
        navigation.open([RadialSlice(title: "Media", symbol: "music.note", action: .submenu([leaf]))])
        _ = navigation.select(0)
        navigation.open([leaf])
        #expect(navigation.submenu == nil)
        #expect(navigation.slices == [leaf])
    }

    @Test func arrowsWrapWithoutDividingByZero() {
        #expect(RadialSelection.rotate(nil, by: 1, count: 6) == 0)
        #expect(RadialSelection.rotate(nil, by: -1, count: 6) == 5)
        #expect(RadialSelection.rotate(5, by: 1, count: 6) == 0)
        #expect(RadialSelection.rotate(0, by: -1, count: 6) == 5)
        #expect(RadialSelection.rotate(0, by: 1, count: 1) == 0)
        #expect(RadialSelection.rotate(nil, by: 1, count: 0) == nil)
    }

    @Test func digitsOnlyPickOneThroughNineWithinBounds() {
        for digit in 1...9 { #expect(RadialSelection.digit(digit, count: 12) == digit - 1) }
        #expect(RadialSelection.digit(0, count: 12) == nil)
        #expect(RadialSelection.digit(10, count: 12) == nil)
        #expect(RadialSelection.digit(6, count: 5) == nil)
        #expect(RadialSelection.digit(1, count: 0) == nil)
    }

    @Test func keystrokesWaitForAllTriggerModifiers() {
        for flags in [CGEventFlags.maskCommand, .maskAlternate, .maskShift, .maskControl, [.maskCommand, .maskAlternate]] {
            #expect(!RadialKeystroke.canPost(heldModifiers: flags.rawValue))
        }
        #expect(RadialKeystroke.canPost(heldModifiers: 0))
        #expect(RadialKeystroke.canPost(heldModifiers: CGEventFlags.maskAlphaShift.rawValue))
    }
}

struct RadialConflictTests {
    @Test func onlyEnabledNonconflictingWheelsOwnKeyboardTriggers() {
        let active = RadialTrigger(wheelID: UUID(), shortcut: RadialKeystroke(keyCode: 49), mouseButton: nil)
        let disabled = RadialTrigger(wheelID: UUID(), shortcut: nil, mouseButton: nil)
        let conflicting = RadialTrigger(wheelID: UUID(), shortcut: active.shortcut, mouseButton: nil)
        #expect(RadialTriggers.enabledKeyboardWheels([active, disabled], isEnabled: true) == [active.wheelID])
        #expect(RadialTriggers.enabledKeyboardWheels([active, disabled], isEnabled: false).isEmpty)
        #expect(RadialTriggers.enabledKeyboardWheels([active, conflicting], isEnabled: true).isEmpty)
        let mouseOnlyConflict = RadialTrigger(wheelID: UUID(), shortcut: RadialKeystroke(keyCode: 7), mouseButton: 3)
        let otherMouse = RadialTrigger(wheelID: UUID(), shortcut: nil, mouseButton: 3)
        #expect(RadialTriggers.enabledKeyboardWheels([mouseOnlyConflict, otherMouse], isEnabled: true) == [mouseOnlyConflict.wheelID])
    }

    @Test func detectsBothKindsOfConflict() {
        let first = RadialTrigger(wheelID: UUID(), shortcut: RadialKeystroke(keyCode: 49), mouseButton: 31)
        let second = RadialTrigger(wheelID: UUID(), shortcut: first.shortcut, mouseButton: 31)
        let conflicts = RadialTriggers.conflicts([first, second])
        #expect(conflicts.count == 2)
        #expect(conflicts.allSatisfy { $0.first == first.wheelID && $0.second == second.wheelID })
        #expect(conflicts.map(\.keyboard) == [true, false])
    }

    @Test func ignoresAbsentDisabledAndDistinctTriggers() {
        let first = RadialTrigger(wheelID: UUID(), shortcut: nil, mouseButton: nil)
        let second = RadialTrigger(wheelID: UUID(), shortcut: nil, mouseButton: nil)
        #expect(RadialTriggers.conflicts([first, second]).isEmpty)
        let third = RadialTrigger(wheelID: UUID(), shortcut: RadialKeystroke(keyCode: 49), mouseButton: 3)
        let fourth = RadialTrigger(wheelID: UUID(), shortcut: RadialKeystroke(keyCode: 49, modifiers: CGEventFlags.maskCommand.rawValue), mouseButton: 4)
        #expect(RadialTriggers.conflicts([third, fourth]).isEmpty)
    }

    @Test func reportsEveryPairExactlyOnce() {
        let triggers = (0..<3).map { _ in RadialTrigger(wheelID: UUID(), mouseButton: 5) }
        #expect(RadialTriggers.conflicts(triggers).count == 3)
        #expect(RadialTriggers.conflicts([]).isEmpty)
    }
}

struct RadialMousePressTests {
    @Test func keepsReleaseOwnershipAfterSettingsChange() {
        var presses = RadialMousePresses()
        let trigger = RadialTrigger(wheelID: UUID(), mouseButton: 31)
        let down = presses.handle(button: 31, isDown: true, triggers: [trigger], isEnabled: true)
        #expect(down == .press(trigger.wheelID))
        let repeated = presses.handle(button: 31, isDown: true, triggers: [trigger], isEnabled: true)
        #expect(repeated == .swallow)
        #expect(presses.hasPendingRelease)
        let up = presses.handle(button: 31, isDown: false, triggers: [], isEnabled: false)
        #expect(up == .release(trigger.wheelID))
        #expect(!presses.hasPendingRelease)
    }

    @Test func passesUnmatchedAndConflictingPresses() {
        var presses = RadialMousePresses()
        let first = RadialTrigger(wheelID: UUID(), mouseButton: 3)
        let second = RadialTrigger(wheelID: UUID(), mouseButton: 3)
        let disabled = presses.handle(button: 3, isDown: true, triggers: [first], isEnabled: false)
        let unmatched = presses.handle(button: 4, isDown: true, triggers: [first], isEnabled: true)
        let conflict = presses.handle(button: 3, isDown: true, triggers: [first, second], isEnabled: true)
        let orphan = presses.handle(button: 3, isDown: false, triggers: [first], isEnabled: true)
        #expect(disabled == .pass && unmatched == .pass && conflict == .pass && orphan == .pass)
        #expect(!presses.hasPendingRelease)
    }

    @Test func simultaneousButtonsReleaseTheirOriginalWheels() {
        var presses = RadialMousePresses()
        let first = RadialTrigger(wheelID: UUID(), mouseButton: 3)
        let second = RadialTrigger(wheelID: UUID(), mouseButton: 4)
        _ = presses.handle(button: 3, isDown: true, triggers: [first, second], isEnabled: true)
        _ = presses.handle(button: 4, isDown: true, triggers: [first, second], isEnabled: true)
        let firstRelease = presses.handle(button: 3, isDown: false, triggers: [second], isEnabled: true)
        #expect(firstRelease == .release(first.wheelID))
        #expect(presses.hasPendingRelease)
        let secondRelease = presses.handle(button: 4, isDown: false, triggers: [], isEnabled: false)
        #expect(secondRelease == .release(second.wheelID))
        #expect(!presses.hasPendingRelease)
    }
}

struct QuickPanelEditTests {
    @Test func decodesOldSettingsAndDefaults() throws {
        let settings = try JSONDecoder().decode(QuickPanelSettings.self, from: Data("{\"isEnabled\":true,\"tiles\":[\"lock\",\"keepAwake\"]}".utf8))
        #expect(settings.isEnabled)
        #expect(settings.tiles == ["lock", "keepAwake"])
        #expect(try JSONDecoder().decode(QuickPanelSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(try JSONDecoder().decode(QuickPanelSettings.self, from: Data("{}".utf8)) == QuickPanelSettings())
        #expect(!QuickPanelSettings().isEnabled)
    }

    @Test func keepsEmptyLayoutsAndRemovesDuplicates() throws {
        let empty = try JSONDecoder().decode(QuickPanelSettings.self, from: Data("{\"tiles\":[]}".utf8))
        #expect(empty.tiles.isEmpty)
        #expect(QuickPanelEdits.normalized(["a", "b", "a", "c"]) == ["a", "b", "c"])
    }

    @Test func hidesAddsAndRejectsUnavailableOrDuplicateTiles() {
        let tiles = ["a", "b", "c"]
        let hidden = QuickPanelEdits.hide("b", in: tiles)
        #expect(hidden == ["a", "c"])
        #expect(QuickPanelEdits.hide("missing", in: tiles) == tiles)
        #expect(QuickPanelEdits.add("b", to: hidden, available: ["a", "b", "c"]) == ["a", "c", "b"])
        #expect(QuickPanelEdits.add("a", to: hidden, available: ["a"]) == hidden)
        #expect(QuickPanelEdits.add("missing", to: hidden, available: []) == hidden)
    }

    @Test func reorderMovesAcrossTilesAndPreservesOthers() {
        #expect(QuickPanelEdits.move("a", to: 3, in: ["a", "b", "c", "d"]) == ["b", "c", "d", "a"])
        #expect(QuickPanelEdits.move("d", to: 0, in: ["a", "b", "c", "d"]) == ["d", "a", "b", "c"])
        #expect(QuickPanelEdits.move("a", to: 0, in: ["a", "b"]) == ["a", "b"])
        #expect(QuickPanelEdits.move("missing", to: 0, in: ["a"]) == ["a"])
        #expect(QuickPanelEdits.move("a", to: -1, in: ["a"]) == ["a"])
        #expect(QuickPanelEdits.move("a", to: 1, in: ["a"]) == ["a"])
        #expect(QuickPanelEdits.move("a", to: 0, in: []).isEmpty)
    }
}
