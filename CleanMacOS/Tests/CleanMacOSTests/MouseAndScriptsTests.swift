import Foundation
import CoreGraphics
import Testing
@testable import CleanMacOS

struct SavedScriptTests {
    @Test func scriptShortcutRequiresEveryFeatureGate() {
        var settings = CommandBarSettings()
        var script = CommandScript(name: "Run", path: "/tmp/tool")
        #expect(!settings.holdsShortcut(for: script))
        for enabled in [false, true] {
            for searches in [false, true] {
                for shortcut in [false, true] {
                    for hidden in [false, true] {
                        settings.isEnabled = enabled
                        settings.searchesScripts = searches
                        script.shortcutEnabled = shortcut
                        script.hidden = hidden
                        #expect(settings.holdsShortcut(for: script) == (enabled && searches && shortcut && !hidden))
                    }
                }
            }
        }
        script.hidden = false
        #expect(settings.holdsShortcut(for: script))
        settings.isEnabled = false
        #expect(!settings.holdsShortcut(for: script))
        settings.isEnabled = true
        script.path = " "
        #expect(!settings.holdsShortcut(for: script))
    }

    @Test func matchesWholeFoldedNamesAndPreservesArgumentCase() {
        let script = CommandScript(name: "Café Full", path: "/tmp/tool")
        #expect(script.argument(in: "ＣＡＦＥ full  Hello\n WOrld ") == "Hello WOrld")
        #expect(script.argument(in: "cafe fuller text") == nil)
        #expect(script.argument(in: "cafe full") == nil)
        #expect(script.argument(in: "cafe") == nil)
    }

    @Test func bareNameAndLongestNameAreExplicit() {
        let short = CommandScript(name: "do", path: "/tmp/a", runOnBareName: true)
        let long = CommandScript(name: "do thing", path: "/tmp/b", runOnBareName: true)
        #expect(CommandScript.match("DO THING Arg", scripts: [short, long])?.script == long)
        #expect(CommandScript.match("do thing", scripts: [short, long])?.argument == "")
        var hidden = long
        hidden.hidden = true
        #expect(CommandScript.match("do thing arg", scripts: [hidden]) == nil)
    }

    @Test func namesAndPathsAreRequiredAndTrimmed() {
        #expect(CommandScript(name: "  ", path: " /tmp/my-script.sh \n").normalized?.name == "my-script")
        #expect(CommandScript(name: " Run ", path: " /tmp/tool ").normalized?.path == "/tmp/tool")
        #expect(CommandScript(name: "Run", path: " \n").normalized == nil)
    }

    @Test func outputIsBoundedAndFailureStillHasOutput() {
        var buffer = ScriptOutputBuffer()
        buffer.append(Data(repeating: 65, count: 70_000))
        buffer.append(Data(repeating: 66, count: 100))
        #expect(buffer.data.count == 65_536)
        #expect(!buffer.text.contains("B"))
        #expect(ScriptResult(output: "partial", status: 1, timedOut: true).rowText == "partial")
        #expect(ScriptResult(output: "", status: 0, timedOut: false).rowText == nil)
        #expect(ScriptResult(output: "", status: 0, timedOut: true).rowText == "Script timed out")
    }

    @Test func oldCommandSettingsKeepSavedLinks() throws {
        let settings = try JSONDecoder().decode(CommandBarSettings.self, from: Data("{\"isEnabled\":true,\"fileFolders\":[\"/tmp\"]}".utf8))
        #expect(settings.isEnabled)
        #expect(settings.fileFolders == ["/tmp"])
        #expect(settings.scripts.isEmpty)
        #expect(!settings.searchesScripts)
    }
}

struct WheelPinchTests {
    @Test func oldInputSettingsPreserveValuesAndDisablePinch() throws {
        let settings = try JSONDecoder().decode(InputSettings.self, from: Data("{\"invertVertical\":true,\"fastMultiplier\":7}".utf8))
        #expect(settings.invertVertical)
        #expect(settings.fastMultiplier == 7)
        #expect(!settings.wheelPinch)
        #expect(settings.pinchModifier == .control)
    }

    @Test func classifierRejectsPhasesAndContinuousTails() {
        var classifier = WheelClassifier()
        let outcome1 = !classifier.isWheel(WheelPacket(continuous: true, phase: 1, y: 1), at: 0)
        #expect(outcome1)
        let outcome2 = !classifier.isWheel(WheelPacket(continuous: true, y: 1), at: 0.99)
        #expect(outcome2)
        let outcome3 = classifier.isWheel(WheelPacket(continuous: true, y: 1), at: 1)
        #expect(outcome3)
        let outcome4 = classifier.isWheel(WheelPacket(continuous: false, y: 1), at: 0.5)
        #expect(outcome4)
        let outcome5 = !classifier.isWheel(WheelPacket(continuous: true, momentum: 1, y: 1), at: 2)
        #expect(outcome5)
        let outcome6 = !classifier.isWheel(WheelPacket(continuous: true, y: 1), at: 2.5)
        #expect(outcome6)
    }

    @Test func exactModifiersOnly() {
        #expect(WheelPinchState.matches(.maskControl, modifier: .control))
        #expect(!WheelPinchState.matches([.maskControl, .maskShift], modifier: .control))
        #expect(!WheelPinchState.matches([], modifier: .none))
        #expect(!WheelPinchState.matches(.maskShift, modifier: .shift))
    }

    @Test func gestureLifecycleUsesPrecisePointAndFractionalDelta() {
        var state = WheelPinchState()
        let packet = WheelPacket(continuous: false, y: 0.25, x: 20, flags: .maskControl)
        let first = state.tick(packet, modifier: .control, invertY: true, invertX: false)
        #expect(first.map(\.phase) == [1, 2])
        #expect(first.last?.amount == -0.00125)
        let outcome7 = state.tick(packet, modifier: .control, invertY: false, invertX: false).map(\.phase) == [2]
        #expect(outcome7)
        var moved = packet
        moved.point.x = 0.001
        let outcome8 = state.tick(moved, modifier: .control, invertY: false, invertX: false).map(\.phase) == [4, 1, 2]
        #expect(outcome8)
        let outcome9 = state.end().map(\.phase) == [4]
        #expect(outcome9)
        let outcome10 = state.end().isEmpty
        #expect(outcome10)
    }

    @Test func horizontalFallbackAndModifierChange() {
        var state = WheelPinchState()
        let packet = WheelPacket(continuous: false, y: 0, x: 2.5, flags: .maskAlternate)
        let outcome11 = state.tick(packet, modifier: .option, invertY: false, invertX: true).last?.amount == -0.0125
        #expect(outcome11)
        var changed = packet
        changed.flags = .maskCommand
        let outcome12 = state.tick(changed, modifier: .command, invertY: false, invertX: false).map(\.phase) == [4, 1, 2]
        #expect(outcome12)
    }
}

struct MouseGestureTests {
    @Test func shortcutValidationAndPostingFlags() {
        #expect(!MouseShortcut.valid(key: 0, flags: .maskShift))
        #expect(MouseShortcut.valid(key: 0, flags: .maskCommand))
        #expect(MouseShortcut.valid(key: 122, flags: []))
        #expect(!MouseShortcut.valid(key: 122, flags: .maskShift))
        let arrow = MouseShortcut(button: 3, key: 123, flags: CGEventFlags.maskControl.rawValue)
        #expect(arrow.postingFlags.contains([.maskControl, .maskSecondaryFn, .maskNumericPad]))
        #expect(MouseShortcut(button: 3, key: 82, flags: 0).postingFlags.contains(.maskNumericPad))
    }

    @Test func wheelBurstUsesDirectionAndQuarterSecondGap() {
        var burst = SideWheelBurst()
        let outcome13 = burst.packet(x: 1, y: 2, at: 0) == nil
        #expect(outcome13)
        let outcome14 = burst.packet(x: 3, y: 1, at: 0)?.fire == true
        #expect(outcome14)
        let outcome15 = burst.packet(x: 3, y: 1, at: 0.1)?.fire == false
        #expect(outcome15)
        let outcome16 = burst.packet(x: -3, y: 1, at: 0.11)?.button == -2
        #expect(outcome16)
        let outcome17 = burst.packet(x: -3, y: 1, at: 0.36)?.fire == true
        #expect(outcome17)
    }

    @Test func dragCommitsByRatioAndLocksVertically() {
        var drag = SpacesDragState(point: .zero)
        let outcome18 = drag.move(to: CGPoint(x: 200, y: -149), at: 0, natural: false) == nil
        #expect(outcome18)
        let outcome19 = drag.move(to: CGPoint(x: 230, y: -200), at: 0.1, natural: false) == .missionControl
        #expect(outcome19)
        let outcome20 = drag.move(to: CGPoint(x: 800, y: 0), at: 1, natural: false) == nil
        #expect(outcome20)
        #expect(drag.fired)
    }

    @Test func horizontalDragCarriesSurplusAndBanksDuringCooldown() {
        var drag = SpacesDragState(point: .zero)
        let outcome21 = drag.move(to: CGPoint(x: 330, y: 0), at: 0, natural: false) == .right
        #expect(outcome21)
        let outcome22 = drag.move(to: CGPoint(x: 900, y: 0), at: 0.1, natural: false) == nil
        #expect(outcome22)
        let outcome23 = drag.move(to: CGPoint(x: 900, y: 0), at: 0.35, natural: false) == .right
        #expect(outcome23)
        let outcome24 = drag.move(to: CGPoint(x: 900, y: 0), at: 1, natural: false) == nil
        #expect(outcome24)
        let outcome25 = drag.move(to: CGPoint(x: 680, y: 0), at: 2, natural: true) == .right
        #expect(outcome25)
    }

    @Test func noMotionIsAClickAndDefaultsAreOff() {
        #expect(!SpacesDragState(point: .zero).fired)
        #expect(!MouseToolsSettings().shortcutsEnabled)
        #expect(!MouseToolsSettings().spacesEnabled)
        #expect(!PointerSettings().accelerationOff)
        #expect(!TrackpadMiddleSettings().pressEnabled)
        #expect(TrackpadMiddleSettings().tapFingers == 0)
    }
}

struct PointerJournalTests {
    let identity = PointerIdentity(vendor: "1", product: "2", location: "3", transport: "USB", uniqueID: "", serial: "")

    @Test func identityPriorityAndAmbiguity() {
        var unique = identity
        unique.uniqueID = "mouse-a"
        var other = unique
        other.location = "new"
        #expect(unique.matches(other))
        other.uniqueID = "mouse-b"
        #expect(!unique.matches(other))
        let entry = PointerJournalEntry(registryID: 1, identity: identity, key: "HIDMouseAcceleration", original: PointerValue(number: 0.5))
        #expect(PointerJournal.uniqueMatch(entry, devices: [(2, identity)]) == 2)
        #expect(PointerJournal.uniqueMatch(entry, devices: [(2, identity), (3, identity)]) == nil)
        #expect(PointerJournal.uniqueMatch(entry, devices: []) == nil)
    }

    @Test func journalRoundTripsInPrivateTemporaryDirectory() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mouse-script-tests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PointerJournal(boot: 123, entries: [PointerJournalEntry(registryID: 9, identity: identity,
                                                                           key: "linear", original: PointerValue(number: 0, boolean: true))])
        let file = directory.appendingPathComponent("journal.json")
        try JSONEncoder().encode(journal).write(to: file, options: .atomic)
        #expect(try JSONDecoder().decode(PointerJournal.self, from: Data(contentsOf: file)) == journal)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PointerJournal.self, from: Data("broken".utf8)) }
    }

    @Test func preservesBooleanVersusNumber() {
        #expect(PointerValue(NSNumber(value: true))?.boolean == true)
        #expect(PointerValue(NSNumber(value: 1))?.boolean == false)
        #expect(PointerValue(NSNumber(value: 0.75))?.number == 0.75)
    }
}

struct TrackpadTouchTests {
    func geometry(_ count: Int, x: Double = 0.5, spread: Double = 0.1) -> TouchGeometry {
        TouchGeometry(count: count, center: CGPoint(x: x, y: 0.5), spread: spread)
    }

    @Test func readsNinetySixByteRecordsAndRejectsBadCoordinates() {
        var data = Data(repeating: 0, count: 288)
        for index in 0..<3 {
            for offset in [32, 36] {
                var coordinate: Float = 0.5
                withUnsafeBytes(of: &coordinate) { data.replaceSubrange((index * 96 + offset)..<(index * 96 + offset + 4), with: $0) }
            }
        }
        #expect(TouchGeometry.read(data, count: 3) == geometry(3, spread: 0))
        var invalid: Float = 1.01
        withUnsafeBytes(of: &invalid) { data.replaceSubrange(32..<36, with: $0) }
        #expect(TouchGeometry.read(data, count: 3) == nil)
        #expect(TouchGeometry.read(Data(), count: 3) == nil)
    }

    @Test func pressRequiresFreshHeldContactsAndRespectsDragConflict() {
        var state = TrackpadTouchState()
        _ = state.frame(geometry(3), count: 3, at: 1, tapFingers: 0, threeFingerDrag: false)
        #expect(!state.qualifiesPress(at: 1.02, threeFingerDrag: false))
        #expect(state.qualifiesPress(at: 1.05, threeFingerDrag: false))
        #expect(!state.qualifiesPress(at: 1.3, threeFingerDrag: false))
        #expect(!state.qualifiesPress(at: 1.05, threeFingerDrag: true))
        _ = state.frame(geometry(4), count: 4, at: 2, tapFingers: 0, threeFingerDrag: true)
        #expect(state.qualifiesPress(at: 2.05, threeFingerDrag: true))
    }

    @Test func lightTapAndDuplicateGuard() {
        var state = TrackpadTouchState()
        let outcome26 = !state.frame(geometry(3), count: 3, at: 1, tapFingers: 3, threeFingerDrag: false)
        #expect(outcome26)
        let outcome27 = !state.frame(geometry(3, x: 0.52), count: 3, at: 1.1, tapFingers: 3, threeFingerDrag: false)
        #expect(outcome27)
        let outcome28 = state.frame(nil, count: 0, at: 1.2, tapFingers: 3, threeFingerDrag: false)
        #expect(outcome28)
        #expect(state.isDuplicate(at: 1.4))
        #expect(!state.isDuplicate(at: 1.6))
    }

    @Test func tapCancelsOnMovementSpreadExtraFingersKeysOrClick() {
        for reason in 0..<6 {
            var state = TrackpadTouchState()
            _ = state.frame(geometry(3), count: 3, at: 1, tapFingers: 3, threeFingerDrag: false)
            switch reason {
            case 0: _ = state.frame(geometry(3, x: 0.54), count: 3, at: 1.1, tapFingers: 3, threeFingerDrag: false)
            case 1: _ = state.frame(geometry(3, spread: 0.15), count: 3, at: 1.1, tapFingers: 3, threeFingerDrag: false)
            case 2: _ = state.frame(geometry(4), count: 4, at: 1.1, tapFingers: 3, threeFingerDrag: false)
            case 3: state.key(at: 1.1)
            case 4: state.physicalClick()
            default: _ = state.frame(nil, count: 3, at: 1.1, tapFingers: 3, threeFingerDrag: false)
            }
            let outcome29 = !state.frame(nil, count: 0, at: 1.2, tapFingers: 3, threeFingerDrag: false)
            #expect(outcome29)
        }
    }

    @Test func tapRejectsLongHoldAndThreeFingerDragConflict() {
        var state = TrackpadTouchState()
        _ = state.frame(geometry(3), count: 3, at: 1, tapFingers: 3, threeFingerDrag: false)
        let outcome30 = !state.frame(nil, count: 0, at: 1.36, tapFingers: 3, threeFingerDrag: false)
        #expect(outcome30)
        _ = state.frame(geometry(3), count: 3, at: 2, tapFingers: 3, threeFingerDrag: true)
        let outcome31 = !state.frame(nil, count: 0, at: 2.1, tapFingers: 3, threeFingerDrag: true)
        #expect(outcome31)
    }
}

struct ScriptRunStateTests {
    let key = ScriptRunKey(id: UUID(), path: "/fixture/tool", argument: "Text")
    let result = ScriptResult(output: "answer", status: 0, timedOut: false)

    @Test func sameRunNeverOverlapsOrRepeatsWithinOpening() {
        var state = ScriptRunState()
        state.open()
        let outcome32 = state.begin(key)
        #expect(outcome32)
        let outcome33 = !state.begin(key)
        #expect(outcome33)
        state.finish(key, result: result, opening: state.opening)
        #expect(state.results[key] == result)
        let outcome34 = !state.begin(key)
        #expect(outcome34)
    }

    @Test func openingChangeDiscardsOldResultButKeepsExecutionCustody() {
        var state = ScriptRunState()
        state.open()
        let opening = state.opening
        let outcome35 = state.begin(key)
        #expect(outcome35)
        state.open()
        let outcome36 = !state.begin(key)
        #expect(outcome36)
        state.finish(key, result: result, opening: opening)
        #expect(state.results.isEmpty)
        let outcome37 = state.begin(key)
        #expect(outcome37)
    }

    @Test func directRunDoesNotPopulateCache() {
        var state = ScriptRunState()
        let outcome38 = state.begin(key, direct: true)
        #expect(outcome38)
        let outcome39 = !state.begin(key, direct: true)
        #expect(outcome39)
        state.finish(key, result: result, opening: nil)
        #expect(state.results.isEmpty)
        let outcome40 = state.begin(key, direct: true)
        #expect(outcome40)
    }
}

struct PointerRecoveryLogicTests {
    func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/mouse-script-tests").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func journalFromPreviousBootIsDeleted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        let store = PointerJournalStore(url: url, boot: 20)
        try store.save(PointerJournal(boot: 10))
        #expect(try store.read() == PointerJournal(boot: 20))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func malformedJournalIsPreservedAndBlocksReading() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("journal.json")
        try Data("{bad}".utf8).write(to: url)
        #expect(throws: (any Error).self) { try PointerJournalStore(url: url, boot: 20).read() }
        #expect(try Data(contentsOf: url) == Data("{bad}".utf8))
    }

    @Test func unwritableJournalCannotBeCommitted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("file")
        try Data().write(to: blocker)
        #expect(throws: (any Error).self) { try PointerJournalStore(url: blocker.appendingPathComponent("journal"), boot: 20).save(PointerJournal(boot: 20)) }
    }

    @Test func linearAccelerationKeepsBooleanType() {
        let boolean = PointerValue(number: 0, boolean: true)
        let result = PointerAccelerationPlan.target(type: "HIDMouseAcceleration", properties: ["HIDUseLinearScalingMouseAcceleration": boolean])
        #expect(result?.original == boolean)
        #expect(result?.target == PointerValue(number: 1, boolean: true))
        let number = PointerAccelerationPlan.target(type: "", properties: ["HIDUseLinearScalingMouseAcceleration": PointerValue(number: 0)])
        #expect(number?.target == PointerValue(number: 1))
    }

    @Test func fallbackOrderAndTrackpadExclusion() {
        let values = ["CustomAcceleration": PointerValue(number: 2), "HIDPointerAcceleration": PointerValue(number: 3), "HIDMouseAcceleration": PointerValue(number: 4)]
        #expect(PointerAccelerationPlan.target(type: "CustomAcceleration", properties: values)?.key == "CustomAcceleration")
        #expect(PointerAccelerationPlan.target(type: "", properties: values)?.key == "HIDPointerAcceleration")
        #expect(PointerAccelerationPlan.target(type: "", properties: ["HIDMouseAcceleration": PointerValue(number: 4)])?.target == PointerValue(number: -1))
        #expect(PointerAccelerationPlan.target(type: "HIDTrackpadAcceleration", properties: values) == nil)
        #expect(PointerAccelerationPlan.target(type: "", properties: [:]) == nil)
    }

    @Test func serialTakesPriorityOverLocation() {
        let a = PointerIdentity(vendor: "1", product: "2", location: "3", transport: "USB", uniqueID: "", serial: "device")
        var b = a
        b.location = "4"
        #expect(a.matches(b))
        b.serial = "another"
        #expect(!a.matches(b))
    }
}

struct ScriptExecutableTests {
    @Test func executesFileDirectlyWithOneArgumentAndMergedOutput() throws {
        let directory = try PointerRecoveryLogicTests().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("argument fixture")
        let script = "#!/bin/sh\nprintf '%s:%s' \"$#\" \"$1\"\nprintf ':stderr' >&2\nexit 7\n"
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let result = CommandScriptRunner.run(path: file.path, argument: "MiXeD ; $(literal) {query}")
        #expect(result.output == "1:MiXeD ; $(literal) {query}:stderr")
        #expect(result.status == 7)
        #expect(!result.timedOut)
    }

    @Test func emptyArgumentIsStillOneArgument() throws {
        let directory = try PointerRecoveryLogicTests().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture")
        try Data("#!/bin/sh\nprintf '%s:%s' \"$#\" \"$1\"\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let result = CommandScriptRunner.run(path: file.path, argument: "")
        #expect(result.output == "1:")
        #expect(result.status == 0)
    }

    @Test func nonExecutableFileFailsWithoutShellFallback() throws {
        let directory = try PointerRecoveryLogicTests().temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fixture")
        try Data("printf unexpected".utf8).write(to: file)
        let result = CommandScriptRunner.run(path: file.path, argument: "")
        #expect(result.failed)
        #expect(!result.output.isEmpty)
    }
}
