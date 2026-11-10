import AppKit
import SwiftUI
import Testing
@testable import CleanMacOS

struct ScratchpadTests {
    private let now = Date(timeIntervalSince1970: 1_794_301_500)

    @Test func managesUpToTwelveTabsAndReusesFreeNames() {
        var state = ScratchpadState(now: now)
        #expect(state.tabs.map(\.name) == ["Scratchpad 1"])
        for _ in 0..<20 { _ = state.addTab(now: now) }
        #expect(state.tabs.count == ScratchpadState.maxTabs)
        #expect(state.tabs.last?.name == "Scratchpad 12")
        let closed = state.closeTab(state.tabs[1].id)
        let added = state.addTab(now: now)
        #expect(closed && added)
        #expect(state.tabs.last?.name == "Scratchpad 2")
    }

    @Test func keepsAtLeastOneTab() {
        var state = ScratchpadState(now: now)
        let closed = state.closeTab(state.tabs[0].id)
        #expect(!closed)
        #expect(state.tabs.count == 1)
    }

    @Test func dropsTabsPastTheirRetention() {
        var state = ScratchpadState(now: now)
        state.tabs[0].text = "old"
        state.tabs[0].edited = now.addingTimeInterval(-2 * 86_400)
        _ = state.addTab(now: now)
        state.tabs[1].text = "fresh"
        state.prune(.day, now: now)
        #expect(state.tabs.map(\.text) == ["fresh"])
        state.tabs[0].edited = now.addingTimeInterval(-60 * 86_400)
        state.prune(.never, now: now)
        #expect(state.tabs.count == 1)
        state.prune(.month, now: now)
        #expect(state.tabs.count == 1 && state.tabs[0].text.isEmpty)
    }

    @Test func namesExportsByTabAndDate() {
        let tab = ScratchTab(name: "Notes", text: "x", edited: now)
        #expect(ScratchpadState.exportName(for: tab, date: now, timeZone: TimeZone(identifier: "UTC")!) == "Notes 2026-11-10.txt")
    }

    @Test func continuesListsOnTheNextLine() {
        #expect(ListContinuation.prefix(after: "- item") == "- ")
        #expect(ListContinuation.prefix(after: "  * nested") == "  * ")
        #expect(ListContinuation.prefix(after: "3. third") == "4. ")
        #expect(ListContinuation.prefix(after: "- [x] done") == "- [ ] ")
        #expect(ListContinuation.prefix(after: "plain") == nil)
        #expect(ListContinuation.prefix(after: "- ") == nil)
    }

    @Test func wrapsTextInMarkdown() {
        #expect(MarkdownStyle.bold.wrap("word") == "**word**")
        #expect(MarkdownStyle.italic.wrap("") == "*text*")
        #expect(MarkdownStyle.link.wrap("site") == "[site](https://)")
        #expect(MarkdownStyle.heading.wrap("Title") == "# Title")
        #expect(MarkdownStyle.bullet.wrap("a\nb") == "- a\n- b")
        #expect(MarkdownStyle.numbered.wrap("a\nb") == "1. a\n2. b")
    }

    @Test func previewsMarkdownLineByLine() {
        let text = "# Plan\n- [ ] buy\n  - [x] milk\n* note\n2. step\n> said\n```\n# raw\n```\nplain"
        #expect(MarkdownPreview.lines(text) == [
            .heading(level: 1, text: "Plan"), .task(indent: 0, isDone: false, text: "buy"), .task(indent: 1, isDone: true, text: "milk"),
            .bullet(indent: 0, text: "note"), .numbered(indent: 0, number: "2", text: "step"), .quote("said"),
            .fence, .code("# raw"), .fence, .plain("plain"),
        ])
    }

    @Test func togglesTasksFromThePreview() {
        let text = "intro [ ] not a task\n- [ ] buy\n- [x] milk"
        #expect(MarkdownPreview.togglingTask(in: text, line: 1) == "intro [ ] not a task\n- [x] buy\n- [x] milk")
        #expect(MarkdownPreview.togglingTask(in: text, line: 2) == "intro [ ] not a task\n- [ ] buy\n- [ ] milk")
        #expect(MarkdownPreview.togglingTask(in: text, line: 0) == text)
        #expect(MarkdownPreview.togglingTask(in: text, line: 9) == text)
        #expect(MarkdownPreview.togglingTask(in: "  - [X] a [x] b", line: 0) == "  - [ ] a [x] b")
    }

    @Test func mapsEditorShortcuts() {
        #expect(ScratchpadKeys.command(keyCode: ScratchpadKeys.tKey, modifiers: .command) == .newTab)
        #expect(ScratchpadKeys.command(keyCode: PanelKeys.closeKey, modifiers: .command) == .closeTab)
        #expect(ScratchpadKeys.command(keyCode: PanelKeys.returnKey, modifiers: .command) == .preview)
        #expect(ScratchpadKeys.command(keyCode: ScratchpadKeys.fKey, modifiers: .command) == .find)
        #expect(ScratchpadKeys.command(keyCode: ScratchpadKeys.gKey, modifiers: .command) == .findNext)
        #expect(ScratchpadKeys.command(keyCode: ScratchpadKeys.gKey, modifiers: [.command, .shift]) == .findPrevious)
        #expect(ScratchpadKeys.command(keyCode: 12, modifiers: .command) == .blocked)
        #expect(ScratchpadKeys.command(keyCode: ScratchpadKeys.tKey, modifiers: []) == nil)
    }

    @Test func savesPrivatelyAndLoadsBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScratchpadStore(fileURL: folder.appendingPathComponent("Scratchpad.json"))
        #expect(store.load() == nil)
        var state = ScratchpadState(now: now)
        state.tabs[0].text = "hello"
        store.save(state)
        #expect(store.load() == state)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}

struct QuitAppsTests {
    private let apps = [
        RunningAppInfo(bundleID: "z", name: "Zed", isRegular: true), RunningAppInfo(bundleID: "a", name: "Arc", isRegular: true),
        RunningAppInfo(bundleID: "com.apple.finder", name: "Finder", isRegular: true), RunningAppInfo(bundleID: "h", name: "Helper", isRegular: false),
        RunningAppInfo(bundleID: "m", name: "Mail", isRegular: true), RunningAppInfo(bundleID: "own", name: "MacKit", isRegular: true),
    ]

    @Test func listsTheFrontAppFirstThenByName() {
        #expect(QuitList.ordered(apps, front: "m", own: "own").map(\.name) == ["Mail", "Arc", "Zed"])
    }

    @Test func batchesSkipKeptAppsAndOptionallyTheFrontOne() {
        let listed = QuitList.ordered(apps, front: "m", own: "own")
        #expect(QuitList.batch(listed, kept: ["a"], exceptFront: "m").map(\.name) == ["Zed"])
        #expect(QuitList.batch(listed, kept: [], exceptFront: nil).map(\.name) == ["Mail", "Arc", "Zed"])
        #expect(QuitList.batch(listed + [RunningAppInfo(bundleID: "com.apple.mobilephone", name: "Phone", isRegular: true)], kept: [], exceptFront: nil).count == 3)
    }

    @Test func jumpsToTheTypedName() {
        let listed = QuitList.ordered(apps, front: "m", own: "own")
        #expect(QuitList.jump(to: "ze", in: listed) == 2)
        #expect(QuitList.jump(to: "A", in: listed) == 1)
        #expect(QuitList.jump(to: "q", in: listed) == nil)
    }

    @Test func mapsPanelKeys() {
        #expect(QuitKeys.command(keyCode: PanelKeys.downKey, modifiers: []) == .move(1))
        #expect(QuitKeys.command(keyCode: QuitKeys.tabKey, modifiers: .shift) == .move(-1))
        #expect(QuitKeys.command(keyCode: PanelKeys.deleteKey, modifiers: .command) == .quitSelected)
        #expect(QuitKeys.command(keyCode: PanelKeys.returnKey, modifiers: .command) == .quitAll)
        #expect(QuitKeys.command(keyCode: PanelKeys.returnKey, modifiers: [.command, .option]) == .quitAllExceptFront)
        #expect(QuitKeys.command(keyCode: PanelKeys.escapeKey, modifiers: []) == .cancel)
        #expect(QuitKeys.command(keyCode: PanelKeys.returnKey, modifiers: []) == nil)
    }
}

struct CameraChoiceTests {
    @Test func keepsTheCurrentCameraWhileItIsThere() {
        #expect(CameraChoice.pick(available: ["a", "b"], preferred: "b", current: "a") == "a")
        #expect(CameraChoice.pick(available: ["a", "b"], preferred: "b", current: "gone") == "b")
        #expect(CameraChoice.pick(available: ["a", "b"], preferred: "x", current: nil) == "a")
        #expect(CameraChoice.pick(available: [], preferred: "b", current: nil) == nil)
    }
}

@MainActor
struct ScratchpadEditorTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-editor-\(UUID().uuidString)", isDirectory: true)

    @Test func editsThroughTheTextViewAndSavesEveryTab() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ScratchpadStore(fileURL: folder.appendingPathComponent("Scratchpad.json"))
        let controller = ScratchpadController(store: store)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ScratchpadController.size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: ScratchpadView(controller: controller))
        settle(window)
        let textView = try #require(controller.textView)

        textView.insertText("- [ ] milk", replacementRange: textView.selectedRange())
        #expect(controller.selectedTab?.text == "- [ ] milk")
        controller.toggleTask(line: 0)
        #expect(controller.selectedTab?.text == "- [x] milk")
        settle(window)
        controller.clear()
        #expect(controller.selectedTab?.text == "")
        settle(window)
        textView.undoManager?.undo()
        #expect(controller.selectedTab?.text == "- [x] milk")

        controller.newTab()
        settle(window)
        #expect(textView.string.isEmpty)
        controller.apply(.bold)
        #expect(controller.selectedTab?.text == "**text**")
        controller.saveNow()
        #expect(store.load()?.tabs.map(\.text) == ["- [x] milk", "**text**"])
    }

    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
