import Foundation
import Testing
import MacKitAudioBridge
@testable import CleanMacOS

struct LeftoverFeaturesTests {
    @Test func olderSettingsKeepTheirValues() throws {
        let clipboard = try JSONDecoder().decode(ClipboardOptions.self, from: Data(#"{"retentionDays":30,"showsSourceIcons":true}"#.utf8))
        #expect(clipboard.layout == .list)
        #expect(clipboard.retentionDays == 30)
        #expect(clipboard.showsSourceIcons)
        let unknown = try JSONDecoder().decode(ClipboardOptions.self, from: Data(#"{"layout":"future"}"#.utf8))
        #expect(unknown.layout == .list)
        let shelf = try JSONDecoder().decode(ShelfSettings.self, from: Data(#"{"isEnabled":true,"excludedApps":["example"]}"#.utf8))
        #expect(shelf.isEnabled)
        #expect(shelf.excludedApps == ["example"])
        #expect(!shelf.peeksAtEdges && !shelf.groupsDrops)
        let mixer = try JSONDecoder().decode(MixerSettings.self, from: Data(#"{"isEnabled":true}"#.utf8))
        #expect(mixer.isEnabled && !mixer.fineVolumeKeys && !mixer.airPlayEnabled)
    }

    @Test func historyMovesOnlyWithinGroupsAndPreservesDates() {
        let pinned = ClipboardItem(text: "pin", isPinned: true)
        let first = ClipboardItem(text: "first")
        let second = ClipboardItem(text: "second")
        var history = ClipboardHistory(items: [first, pinned, second])
        #expect(history.items.map(\.id) == [pinned.id, first.id, second.id])
        let check27 = !history.move(first.id, direction: -1)
        #expect(check27)
        let check28 = !history.move(first.id, direction: 1, query: "x")
        #expect(check28)
        let check29 = history.move(second.id, direction: -1, query: " \n")
        #expect(check29)
        #expect(history.items.map(\.id) == [pinned.id, second.id, first.id])
        #expect(history.items.last?.createdAt == first.createdAt)
        history.insert(ClipboardItem(text: "third"), maxItems: 2)
        #expect(!history.items.contains { $0.id == first.id })
    }

    @Test func usingHistoryPreservesPinOrderAndPileOrder() {
        let a = ClipboardItem(text: "a", isPinned: true)
        let b = ClipboardItem(text: "b", isPinned: true)
        let c = ClipboardItem(text: "c")
        let d = ClipboardItem(text: "d")
        var history = ClipboardHistory(items: [a, b, c, d])
        history.recordUse([b.id, d.id, c.id], at: Date(timeIntervalSince1970: 100))
        #expect(history.items.map(\.id) == [a.id, b.id, d.id, c.id])
        history.insert(ClipboardItem(text: "b"), maxItems: 10)
        #expect(history.items.first?.id == b.id)
    }

    @Test func cardsHaveClampedGeometryAndPreserveLineBreaks() {
        let frame = ClipboardCardGeometry.frame(in: CGRect(x: -1440, y: 20, width: 1440, height: 900))
        #expect(frame == CGRect(x: -1424, y: 28, width: 1408, height: 318))
        #expect(ClipboardCardGeometry.frame(in: CGRect(x: 0, y: 0, width: 500, height: 200)).height == 184)
        #expect(ClipboardCardGeometry.text("a\tb\nc") == "a b\nc")
        #expect(ClipboardCardGeometry.text(String(repeating: "x", count: 2001)).count == 2001)
    }

    @Test func cardKeysLeaveListCaretAloneAndSupportKeypad() {
        #expect(PanelKeys.command(keyCode: 123, modifiers: [], usedArrows: false, hasPile: false) == nil)
        #expect(PanelKeys.command(keyCode: 123, modifiers: [], usedArrows: false, hasPile: false, cards: true) == .move(-1))
        #expect(PanelKeys.command(keyCode: 83, modifiers: .command, usedArrows: false, hasPile: false) == .pasteNumber(1))
        #expect(PanelKeys.command(keyCode: 51, modifiers: .command, usedArrows: false, hasPile: false) == nil)
    }

    @Test func shelfGroupsMergeFlattenAndProtectPins() {
        let a = ShelfItem(kind: .text, text: "a")
        let b = ShelfItem(kind: .text, text: "b")
        var shelf = ShelfCollection()
        let added = shelf.add([a, b], grouped: true)
        #expect(added.count == 1)
        #expect(shelf.items.first?.title == "a +1")
        let pile = shelf.items[0]
        shelf.togglePin(pile.id)
        shelf.removeAfterDragOut([a.id, b.id])
        #expect(shelf.leaves.count == 2)
        #expect(shelf.visible(expanded: [pile.id]).count == 3)
        shelf.remove([b.id])
        #expect(shelf.items.first?.id == a.id)
        #expect(shelf.items.first?.isPinned == true)
    }

    @Test func shelfRejectsOverflowAndCyclesAtomically() {
        let a = ShelfItem(kind: .text, text: "a")
        let b = ShelfItem(kind: .text, text: "b")
        var shelf = ShelfCollection()
        _ = shelf.add([a, b], grouped: true)
        let saved = shelf
        let check86 = shelf.add([a], target: shelf.items[0].id, moving: [a.id]).isEmpty
        #expect(check86)
        #expect(shelf == saved)
        let check88 = shelf.add((0..<200).map { ShelfItem(kind: .text, text: "new \($0)") }).isEmpty
        #expect(check88)
        #expect(shelf == saved)
        let check90 = shelf.add([a], moving: [a.id]).isEmpty
        #expect(check90)
    }

    @Test func shelfNestedTargetsKeepIdentityAndPin() {
        let a = ShelfItem(kind: .text, text: "a", isPinned: true)
        let b = ShelfItem(kind: .text, text: "b")
        var shelf = ShelfCollection(items: [a])
        _ = shelf.add([b], grouped: true, target: a.id)
        #expect(shelf.items[0].id == a.id && shelf.items[0].isPinned)
        let child = shelf.items[0].children![0]
        _ = shelf.add([ShelfItem(kind: .text, text: "c")], grouped: true, target: child.id)
        #expect(shelf.leaves.count == 3)
        #expect(shelf.items[0].children![0].isPile)
    }

    @Test func edgeDwellRejectsSharedEdgesDockAndTop() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let visible = CGRect(x: 60, y: 0, width: 940, height: 775)
        #expect(ShelfEdge.candidate(at: CGPoint(x: 20, y: 400), screens: [(frame, visible)]) == nil)
        #expect(ShelfEdge.candidate(at: CGPoint(x: 500, y: 799), screens: [(frame, visible)]) == nil)
        let second = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        #expect(ShelfEdge.candidate(at: CGPoint(x: 990, y: 400), screens: [(frame, visible), (second, second)]) == nil)
        let edge = ShelfEdge(screen: frame, visible: frame, side: .left)
        var dwell = ShelfEdgeDwell()
        let result114 = dwell.update(edge, at: 0) == nil
        #expect(result114)
        let result115 = dwell.update(edge, at: 0.149) == nil
        #expect(result115)
        let result116 = dwell.update(edge, at: 0.151) == edge
        #expect(result116)
        let result117 = dwell.update(nil, at: 0.2) == nil
        #expect(result117)
        let result118 = dwell.update(edge, at: 0.3) == nil
        #expect(result118)
        let peek = edge.frame(at: CGPoint(x: 0, y: 500), size: CGSize(width: 304, height: 280), peeking: true)
        #expect(abs(peek.maxX - 304 / 3) < 0.001)
        #expect(edge.isTooFar(CGPoint(x: 331, y: 400)))
    }

    @Test func promisesRejectSymlinksAndOverflow() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image.png")
        try Data([1, 2]).write(to: file)
        #expect(ShelfPromisePlan.isSafe(file, inside: folder))
        let link = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(!ShelfPromisePlan.isSafe(link, inside: folder))
        #expect(!ShelfPromisePlan.isSafe(folder, inside: folder))
        #expect(ShelfPromisePlan.accepts(receiverNames: [[], ["a", "b"]], companions: 1, freeSlots: 4))
        #expect(!ShelfPromisePlan.accepts(receiverNames: [[], ["a", "b"]], companions: 1, freeSlots: 3))
    }

    @Test func fineVolumeGatesBurstsAndReversals() {
        var gate = VolumeBurstGate()
        let check146 = gate.accepts(0, at: 1)
        #expect(check146)
        let check147 = !gate.accepts(0, at: 1.01)
        #expect(check147)
        let check148 = !gate.accepts(1, at: 1.04)
        #expect(check148)
        let check149 = !gate.accepts(1, at: 1.08)
        #expect(check149)
        let check150 = gate.accepts(1, at: 1.12)
        #expect(check150)
        let check151 = gate.accepts(0, at: 2)
        #expect(check151)
    }

    @Test func fineVolumeTracksWholePressAndOrphanEvents() {
        var press = FineVolumePress()
        let result151 = press.handle(code: 0, down: true, repeated: true, modified: false, at: 0) == .pass
        #expect(result151)
        let result152 = press.handle(code: 0, down: true, repeated: false, modified: true, at: 1) == .pass
        #expect(result152)
        let result153 = press.handle(code: 0, down: true, repeated: true, modified: false, at: 2) == .pass
        #expect(result153)
        let result154 = press.handle(code: 0, down: false, repeated: false, modified: false, at: 3) == .pass
        #expect(result154)
        let result155 = press.handle(code: 0, down: true, repeated: false, modified: false, at: 4) == .step
        #expect(result155)
        let result156 = press.handle(code: 0, down: true, repeated: true, modified: true, at: 5) == .step
        #expect(result156)
        let result157 = press.handle(code: 0, down: false, repeated: false, modified: false, at: 6) == .swallow
        #expect(result157)
        let result158 = press.handle(code: 7, down: true, repeated: false, modified: false, at: 7) == .pass
        #expect(result158)
    }

    @Test func secureInputAttributionDoesNotGuessAnotherUser() {
        let sessions: [[String: Any]] = [["kCGSSessionUserIDKey": NSNumber(value: 502), "kCGSSessionSecureInputPID": NSNumber(value: 9)]]
        #expect(SecureInputAttribution.holder(in: sessions, uid: 501) == nil)
        #expect(SecureInputAttribution.resolve(enabled: true, readSucceeded: false, pid: nil, ownPID: 1, name: nil, regular: false, running: false) == .unknown)
        #expect(SecureInputAttribution.resolve(enabled: true, readSucceeded: true, pid: 1, ownPID: 1, name: "MacKit", regular: true, running: true) == .unknown)
        #expect(SecureInputAttribution.resolve(enabled: true, readSucceeded: true, pid: 2, ownPID: 1, name: "Editor", regular: true, running: true) == .app(pid: 2, name: "Editor"))
    }

    @Test func audioRingBoundsAndWrapsWithoutOverwritingUnreadFrames() throws {
        let ring = try #require(MKAudioRingCreate())
        defer { MKAudioRingDestroy(ring) }
        for index in 0..<65540 { MKAudioRingWrite(ring, Float(index), -Float(index)) }
        #expect(MKAudioRingCount(ring) == 65536)
        var samples = [Float](repeating: 0, count: 131072)
        #expect(MKAudioRingRead(ring, &samples, 65536) == 65536)
        #expect(samples[0] == 0 && samples[131070] == 65535 && samples[131071] == -65535)
        MKAudioRingWrite(ring, 3, 4)
        #expect(MKAudioRingRead(ring, &samples, 1) == 1)
        #expect(samples[0] == 3 && samples[1] == 4)
    }
    @Test func transferMathAndLegacySetting() throws {
        #expect(!TransferProgressState.crossesVolumes(sources: [nil, "a"], destination: "a"))
        #expect(TransferProgressState.crossesVolumes(sources: ["b"], destination: "a"))
        #expect(!TransferProgressState.crossesVolumes(sources: ["b"], destination: nil))
        let state = TransferProgressState(totalBytes: 100, finishedBytes: 30)
        #expect(state.fraction(currentBytes: 20) == 0.5)
        #expect(state.fraction(currentBytes: 200) == 1)
        #expect(TransferProgressState(containsFolders: true).fraction(currentBytes: 20) == nil)
        let settings = try JSONDecoder().decode(FinderSettings.self, from: Data(#"{"cutsAndPastes":true}"#.utf8))
        #expect(settings.cutsAndPastes && !settings.showsTransferProgress)
    }

    @Test func airPlayNamesResamplingAndLimiting() {
        #expect(AirPlayRouteLogic.name([" B ", "A", "Unknown", "A"]) == "A + B")
        #expect(AirPlayRouteLogic.name(["", "Unknown"]) == nil)
        var resampler = AirPlayResampler()
        resampler.append([0, 0, 1, -1, 0, 0])
        let output = resampler.render(frames: 4, sampleRate: 22050)
        #expect(output == [0, 0, 0.5, -0.5, 1, -1, 0.5, -0.5])
        let limited = AirPlayRouteLogic.pcm([2, -2, .nan, .infinity])
        #expect(limited[0] > 30000 && limited[0] < 32767)
        #expect(limited[1] == -limited[0])
        #expect(limited[2] == 0 && limited[3] == 0)
    }

    @Test func promiseCopiesKeepNamesAndUsePrivateIndependentFolders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.png")
        try Data([1, 2, 3]).write(to: source)
        let blocked = root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let suite = "mackit.promise.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ShelfStore(defaults: defaults, payloadFolder: blocked)
        let fallback = root.appendingPathComponent("fallback")
        let first = try #require(store.copyPromise(source, fallback: fallback))
        let second = try #require(store.copyPromise(source, fallback: fallback))
        #expect(first.file.lastPathComponent == "original.png")
        #expect(first.owner != second.owner)
        #expect(try Data(contentsOf: first.file) == Data([1, 2, 3]))
        #expect((try FileManager.default.attributesOfItem(atPath: first.owner.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let batch = ShelfPromiseBatch(target: nil)
        #expect(batch.keep(first.owner))
        batch.finish(accepted: false)
        #expect(!FileManager.default.fileExists(atPath: first.owner.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        batch.finish(accepted: true)
        #expect(batch.isCancelled)
    }

    @Test func mixerCompensationIsBoundedAndChangesRampBothWays() {
        #expect(MixerGainRamp.compensation(channels: 0) == 1)
        #expect(MixerGainRamp.compensation(channels: 2) == 1)
        #expect(MixerGainRamp.compensation(channels: 6) == 3)
        #expect(MixerGainRamp.compensation(channels: 32) == 4)
        var ramp = MixerGainRamp()
        let up = ramp.next(target: 2, frames: 480, sampleRate: 48000)
        #expect(up.start == 1 && up.end > 1 && up.end < 2)
        let down = ramp.next(target: 0, frames: 480, sampleRate: 48000)
        #expect(down.start == up.end && down.end > 0 && down.end < down.start)
    }

}
