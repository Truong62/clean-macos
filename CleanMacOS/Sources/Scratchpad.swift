import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct ScratchpadSettings: Codable, Equatable {
    static let textSizes: ClosedRange<Double> = 10...22

    var isEnabled = false
    var retention = ScratchRetention.never
    var closesOnOutsideClick = true
    var textSize: Double = 13
    var opacity: Double = 0
    var showsFormatBar = false
}

@MainActor
final class ScratchpadController: NSObject, ObservableObject, NSWindowDelegate {
    static let settingsKey = "scratchpad.settings"
    static let size = NSSize(width: 380, height: 300)
    static let minimumSize = NSSize(width: 280, height: 220)
    static let heightShare: CGFloat = 0.58
    static let saveDelay: TimeInterval = 0.8

    @Published var settings: ScratchpadSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if settings.isEnabled { KeyboardShortcuts.enable([.scratchpad]) } else { KeyboardShortcuts.disable([.scratchpad]) }
        }
    }
    @Published private(set) var state: ScratchpadState { didSet { scheduleSave() } }
    @Published private(set) var isPreviewing = false
    @Published var isPinned = false
    @Published var pendingClose: UUID?

    weak var textView: NSTextView?
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var saveWork: DispatchWorkItem?
    private var isExporting = false
    private let store: ScratchpadStore

    init(store: ScratchpadStore = ScratchpadStore()) {
        self.store = store
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ScratchpadSettings.self, from: $0) }
            ?? ScratchpadSettings()
        state = store.load() ?? ScratchpadState(now: Date())
        super.init()
        KeyboardShortcuts.onKeyUp(for: .scratchpad) { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        if !settings.isEnabled { KeyboardShortcuts.disable([.scratchpad]) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    var isOpen: Bool { panel?.isVisible == true }

    var selectedTab: ScratchTab? { state.tabs.first { $0.id == state.selected } ?? state.tabs.first }

    func toggle() {
        guard let panel, panel.isVisible else { return open() }
        if panel.isKeyWindow { hide() } else { focus(panel) }
    }

    func open() {
        state.prune(settings.retention, now: Date())
        let panel = self.panel ?? makePanel()
        self.panel = panel
        focus(panel)
        installKeyMonitor()
    }

    func hide() {
        saveNow()
        removeKeyMonitor()
        pendingClose = nil
        panel?.orderOut(nil)
    }

    func select(_ id: UUID) {
        pendingClose = nil
        state.selected = id
    }

    func newTab() {
        if !state.addTab(now: Date()) { NSSound.beep() }
    }

    func requestClose(_ id: UUID) {
        guard state.tabs.count > 1 else { return hide() }
        if state.tabs.first(where: { $0.id == id })?.text.isEmpty == false { pendingClose = id } else { closeTab(id) }
    }

    func closeTab(_ id: UUID) {
        pendingClose = nil
        state.closeTab(id)
    }

    func updateText(_ text: String) {
        guard let index = state.tabs.firstIndex(where: { $0.id == selectedTab?.id }), state.tabs[index].text != text else { return }
        state.tabs[index].text = text
        state.tabs[index].edited = Date()
    }

    func togglePreview() {
        isPreviewing.toggle()
        panel?.makeFirstResponder(isPreviewing ? nil : textView)
    }

    func apply(_ style: MarkdownStyle) {
        guard let textView, !isPreviewing else { return }
        let range = textView.selectedRange()
        textView.insertText(style.wrap((textView.string as NSString).substring(with: range)), replacementRange: range)
        panel?.makeFirstResponder(textView)
    }

    func toggleTask(line: Int) {
        guard let text = selectedTab?.text else { return }
        replaceAll(with: MarkdownPreview.togglingTask(in: text, line: line))
    }

    func clear() {
        replaceAll(with: "")
    }

    func copyAll() {
        guard let text = selectedTab?.text, !text.isEmpty else { return NSSound.beep() }
        ScreenTools.copy(text)
    }

    func export() {
        guard let tab = selectedTab, let panel else { return }
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = ScratchpadState.exportName(for: tab, date: Date())
        savePanel.allowedContentTypes = [.plainText]
        isExporting = true
        NSApp.activate()
        savePanel.beginSheetModal(for: panel) { [weak self] response in
            MainActor.assumeIsolated {
                self?.isExporting = false
                guard response == .OK, let url = savePanel.url else { return }
                do {
                    try tab.text.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    NSLog("ScratchpadController.export failed for \(url.path): \(error.localizedDescription)")
                    NSSound.beep()
                }
            }
        }
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        store.save(state)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard settings.closesOnOutsideClick, !isPinned, !isExporting else { return }
        hide()
    }

    private func replaceAll(with text: String) {
        guard let textView, textView.string != text else { return }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: all, replacementString: text) else { return }
        textView.replaceCharacters(in: all, with: text)
        textView.didChangeText()
    }

    private func focus(_ panel: NSPanel) {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        if !isPreviewing, let textView { panel.makeFirstResponder(textView) }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = Self.minimumSize
        let host = NSHostingController(rootView: ScratchpadView(controller: self))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(Self.size)
        let mouse = NSEvent.mouseLocation
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.minY + visible.height * Self.heightShare - Self.size.height / 2))
        }
        panel.delegate = self
        return panel
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let windowNumber = event.windowNumber
            let isHandled = MainActor.assumeIsolated { self?.handleKey(keyCode, modifiers: modifiers, windowNumber: windowNumber) ?? false }
            return isHandled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handleKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, windowNumber: Int) -> Bool {
        guard let panel, panel.windowNumber == windowNumber else { return false }
        let isReturn = keyCode == PanelKeys.returnKey || keyCode == PanelKeys.enterKey
        if let pendingClose, isReturn {
            closeTab(pendingClose)
            return true
        }
        if keyCode == PanelKeys.escapeKey { return handleEscape(in: panel) }
        if isReturn, modifiers.intersection(PanelKeys.relevantModifiers) == .shift { return continueList(in: panel) }
        guard let command = ScratchpadKeys.command(keyCode: keyCode, modifiers: modifiers) else { return false }
        switch command {
        case .newTab: newTab()
        case .closeTab: if let id = selectedTab?.id { requestClose(id) }
        case .preview: togglePreview()
        case .find: find(.showFindInterface)
        case .findNext: find(.nextMatch)
        case .findPrevious: find(.previousMatch)
        case .blocked: NSSound.beep()
        }
        return true
    }

    private func handleEscape(in panel: NSPanel) -> Bool {
        if pendingClose != nil {
            pendingClose = nil
            return true
        }
        if let responder = panel.firstResponder as? NSTextView, responder.isFieldEditor || responder.hasMarkedText() { return false }
        hide()
        return true
    }

    private func continueList(in panel: NSPanel) -> Bool {
        guard let textView, panel.firstResponder === textView, !textView.hasMarkedText() else { return false }
        let text = textView.string as NSString
        let cursor = textView.selectedRange()
        let lineStart = text.lineRange(for: NSRange(location: cursor.location, length: 0)).location
        guard let prefix = ListContinuation.prefix(after: text.substring(with: NSRange(location: lineStart, length: cursor.location - lineStart))) else {
            return false
        }
        textView.insertText("\n" + prefix, replacementRange: cursor)
        return true
    }

    private func find(_ action: NSTextFinder.Action) {
        guard let textView, !isPreviewing else { return }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
    }
}

struct ScratchEditor: NSViewRepresentable {
    @ObservedObject var controller: ScratchpadController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.textStorage?.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.font = .systemFont(ofSize: controller.settings.textSize)
        textView.string = controller.selectedTab?.text ?? ""
        context.coordinator.shownTab = controller.selectedTab?.id
        controller.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.font?.pointSize != CGFloat(controller.settings.textSize) { textView.font = .systemFont(ofSize: controller.settings.textSize) }
        let text = controller.selectedTab?.text ?? ""
        if context.coordinator.shownTab != controller.selectedTab?.id {
            context.coordinator.shownTab = controller.selectedTab?.id
            textView.string = text
            textView.undoManager?.removeAllActions()
            if !controller.isPreviewing { textView.window?.makeFirstResponder(textView) }
        } else if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextStorageDelegate {
        let controller: ScratchpadController
        var shownTab: UUID?

        init(controller: ScratchpadController) {
            self.controller = controller
        }

        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange,
                                     changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            let text = textStorage.string
            MainActor.assumeIsolated { controller.updateText(text) }
        }
    }
}

struct ScratchpadView: View {
    static let indentWidth: CGFloat = 16

    @ObservedObject var controller: ScratchpadController

    var body: some View {
        VStack(spacing: 0) {
            header
            if controller.settings.showsFormatBar { formatBar }
            ZStack {
                ScratchEditor(controller: controller).opacity(controller.isPreviewing ? 0 : 1)
                if controller.isPreviewing { preview }
            }
            Divider().opacity(0.4)
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(controller.settings.opacity))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { if let id = controller.pendingClose { confirmClose(id) } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(controller.state.tabs) { tab in tabChip(tab) }
                }
            }
            Button { controller.newTab() } label: { Image(systemName: "plus") }
                .disabled(controller.state.tabs.count >= ScratchpadState.maxTabs)
                .help("New tab (⌘T)")
            Button { controller.isPinned.toggle() } label: { Image(systemName: controller.isPinned ? "pin.fill" : "pin") }
                .help(controller.isPinned ? "Unpin" : "Keep open when clicking elsewhere")
            Button { controller.hide() } label: { Image(systemName: "xmark") }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func tabChip(_ tab: ScratchTab) -> some View {
        let isSelected = tab.id == controller.selectedTab?.id
        return HStack(spacing: 4) {
            Text(tab.name).font(.caption.weight(isSelected ? .semibold : .regular)).lineLimit(1)
            if isSelected, controller.state.tabs.count > 1 {
                Button { controller.requestClose(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
        .contentShape(Capsule())
        .onTapGesture { controller.select(tab.id) }
    }

    private var formatBar: some View {
        HStack(spacing: 2) {
            ForEach(MarkdownStyle.allCases) { style in
                Button { controller.apply(style) } label: { Image(systemName: style.symbol).frame(width: 22, height: 20) }
                    .help(style.rawValue.capitalized)
            }
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .disabled(controller.isPreviewing)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $controller.settings.showsFormatBar) { Image(systemName: "textformat") }
                .toggleStyle(.button)
                .help("Formatting buttons")
            Toggle(isOn: Binding(get: { controller.isPreviewing }, set: { _ in controller.togglePreview() })) { Image(systemName: "eye") }
                .toggleStyle(.button)
                .help("Preview (⌘↩)")
            Spacer()
            Button { controller.copyAll() } label: { Image(systemName: "doc.on.doc") }.help("Copy all")
            Button { controller.export() } label: { Image(systemName: "square.and.arrow.up") }.help("Export as a text file")
            Button { controller.clear() } label: { Image(systemName: "trash") }.help("Clear (undo with ⌘Z)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(MarkdownPreview.lines(controller.selectedTab?.text ?? "").enumerated()), id: \.offset) { index, line in
                    previewRow(line, index: index)
                }
            }
            .font(.system(size: controller.settings.textSize))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func previewRow(_ line: PreviewLine, index: Int) -> some View {
        let size = controller.settings.textSize
        switch line {
        case .heading(let level, let text):
            inline(text).font(.system(size: size + CGFloat(max(0, 4 - level)) * 3, weight: .bold))
        case .task(let indent, let isDone, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button { controller.toggleTask(line: index) } label: { Image(systemName: isDone ? "checkmark.square.fill" : "square") }
                    .buttonStyle(.plain)
                inline(text).strikethrough(isDone).foregroundStyle(isDone ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(indent) * Self.indentWidth)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * Self.indentWidth)
        case .numbered(let indent, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").monospacedDigit()
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * Self.indentWidth)
        case .quote(let text):
            inline(text).foregroundStyle(.secondary).padding(.leading, 10).overlay(alignment: .leading) { Capsule().fill(.tertiary).frame(width: 3) }
        case .fence:
            EmptyView()
        case .code(let text):
            Text(text.isEmpty ? " " : text).font(.system(size: size, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06))
        case .plain(let text):
            inline(text)
        }
    }

    private func inline(_ text: String) -> Text {
        guard !text.isEmpty else { return Text(" ") }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    private func confirmClose(_ id: UUID) -> some View {
        let name = controller.state.tabs.first { $0.id == id }?.name ?? ""
        return VStack(spacing: 10) {
            Text("Close “\(name)”?").font(.headline)
            Text("Its text will be deleted.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { controller.pendingClose = nil }
                Button("Close Tab") { controller.closeTab(id) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
    }
}

struct ScratchpadSettingsCard: View {
    @EnvironmentObject var scratchpad: ScratchpadController

    var body: some View {
        CardSection(title: "Scratchpad", icon: "note.text") {
            HStack {
                Button { scratchpad.open() } label: { Label("Open Scratchpad", systemImage: "note.text") }
                    .buttonStyle(.borderedProminent)
                Spacer()
            }
            Text("A floating notepad with up to \(ScratchpadState.maxTabs) tabs and Markdown preview. Notes stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Open the scratchpad with a shortcut", isOn: $scratchpad.settings.isEnabled)
            if scratchpad.settings.isEnabled {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .scratchpad)
                }
            }
            Picker("Delete tabs not edited", selection: $scratchpad.settings.retention) {
                ForEach(ScratchRetention.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 320)
            Toggle("Close when clicking outside", isOn: $scratchpad.settings.closesOnOutsideClick)
            HStack {
                Text("Text size")
                Slider(value: $scratchpad.settings.textSize, in: ScratchpadSettings.textSizes, step: 1).frame(maxWidth: 200)
                Text("\(Int(scratchpad.settings.textSize)) pt").monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Text("Background")
                Slider(value: $scratchpad.settings.opacity, in: 0...1).frame(maxWidth: 200)
                Text("\(Int(scratchpad.settings.opacity * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Text("⌘T new tab · ⌘W close tab · ⌘F find · ⌘↩ preview · ⇧↩ continues a list").font(.caption).foregroundStyle(.secondary)
        }
    }
}
