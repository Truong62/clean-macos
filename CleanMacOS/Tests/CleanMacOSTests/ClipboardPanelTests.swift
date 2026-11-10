import AppKit
import Testing
@testable import CleanMacOS

struct ClipboardPanelTests {
    private func command(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], arrows: Bool = false, pile: Bool = false) -> PanelCommand? {
        PanelKeys.command(keyCode: keyCode, modifiers: modifiers, usedArrows: arrows, hasPile: pile)
    }

    @Test func mapsKeysToCommands() {
        #expect(command(125, [.numericPad, .function]) == .move(1))
        #expect(command(126) == .move(-1))
        #expect(command(45, .control) == .move(1))
        #expect(command(35, .control) == .move(-1))
        #expect(command(36) == .paste)
        #expect(command(36, .shift) == .copyOnly)
        #expect(command(36, .command) == .togglePile)
        #expect(command(20, .command) == .pasteNumber(3))
        #expect(command(25, .command) == .pasteNumber(9))
        #expect(command(35, .option) == .togglePin)
        #expect(command(51, .option) == .delete)
        #expect(command(51, .command) == .deletePile)
        #expect(command(8, .command, pile: true) == .copyOnly)
        #expect(command(8, .command) == nil)
        #expect(command(49, arrows: true) == .togglePreview)
        #expect(command(49) == nil)
        #expect(command(53) == .escape)
        #expect(command(0, arrows: true) == nil)
    }

    @Test func movesWithinTheListAndBuildsAPile() {
        let items = (1...4).map { ClipboardItem(text: "item \($0)") }
        var state = ClipboardPanelState()
        state.move(by: -1, count: items.count)
        #expect(state.selection == 0)
        state.move(by: 10, count: items.count)
        #expect(state.selection == 3)
        state.togglePile(items[3].id)
        state.togglePile(items[0].id)
        #expect(state.pileItems(in: items).map(\.text) == ["item 1", "item 4"])
        state.togglePile(items[0].id)
        #expect(state.pileItems(in: items).map(\.text) == ["item 4"])
        state.selection = 1
        state.extendPile(through: 3, in: items)
        #expect(state.pileItems(in: items).map(\.text) == ["item 2", "item 3", "item 4"])
        #expect(state.selection == 3)
    }

    @Test func joinsAPileIntoText() {
        let items = [ClipboardItem(text: "first"), ClipboardItem(text: "", kind: .files, files: ["/a", "/b"]), ClipboardItem(text: "last")]
        #expect(ClipboardPile.text(items) == "first\n/a\n/b\nlast")
        #expect(ClipboardPile.allFiles([ClipboardItem(text: "", kind: .files, files: ["/a"])]))
        #expect(!ClipboardPile.allFiles(items))
    }

    @Test func prettyPrintsJSONOnly() {
        #expect(PrettyJSON.format(#"{"b":1,"a":[true]}"#) == "{\n  \"a\" : [\n    true\n  ],\n  \"b\" : 1\n}")
        #expect(PrettyJSON.format("not json") == nil)
        #expect(PrettyJSON.format("42") == nil)
    }

    @Test func shortensTheLatestCopyForTheMenuBar() {
        #expect(ClipboardItem(text: "Hello\nworld and more").menuTitle(length: 5) == "Hello…")
        #expect(ClipboardItem(text: "Short").menuTitle(length: 20) == "Short")
    }
}

@MainActor
struct ClipboardPanelModelTests {
    private func makeClipboard() -> ClipboardViewModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let monitor = ClipboardMonitor(pasteboard: NSPasteboard(name: .init("mackit.tests.\(UUID().uuidString)")))
        let clipboard = ClipboardViewModel(store: ClipboardStore(fileURL: folder.appendingPathComponent("clipboard-history.json")), monitor: monitor)
        clipboard.clearAll()
        return clipboard
    }

    @Test func keyboardCommandsActOnTheSelectionAndThePile() {
        let clipboard = makeClipboard()
        ["a", "b", "c"].forEach(clipboard.add)
        let model = ClipboardPanelModel(clipboard: clipboard)
        var pasted: [[String]] = []
        var closed = 0
        model.onPaste = { pasted.append($0.map(\.text)) }
        model.onClose = { closed += 1 }

        model.perform(.move(1))
        model.perform(.togglePin)
        #expect(model.visible.map(\.text) == ["b", "c", "a"])
        #expect(model.selected?.text == "b")

        model.perform(.togglePile)
        model.perform(.move(1))
        model.perform(.togglePile)
        model.perform(.paste)
        #expect(pasted == [["b", "c"]])

        model.perform(.escape)
        #expect(model.state.pile.isEmpty && closed == 0)
        model.perform(.escape)
        #expect(closed == 1)

        model.perform(.delete)
        #expect(model.visible.map(\.text) == ["b", "a"])
        model.perform(.pasteNumber(2))
        #expect(pasted.last == ["a"])
        clipboard.togglePin(clipboard.items[0])
        clipboard.clearAll()
    }

    @Test func spaceTogglesThePreviewOnlyAfterArrowKeys() {
        let model = ClipboardPanelModel(clipboard: makeClipboard())
        let before = model.showsPreview
        #expect(!model.handle(keyCode: PanelKeys.spaceKey, modifiers: []))
        #expect(model.handle(keyCode: PanelKeys.downKey, modifiers: [.numericPad, .function]))
        #expect(model.handle(keyCode: PanelKeys.spaceKey, modifiers: []))
        #expect(model.showsPreview != before)
        #expect(!model.handle(keyCode: 0, modifiers: []))
        #expect(!model.handle(keyCode: PanelKeys.spaceKey, modifiers: []))
        model.showsPreview = before
    }
}
