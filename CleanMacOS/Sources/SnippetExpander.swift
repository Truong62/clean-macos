import AppKit
import ApplicationServices
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

struct SnippetSettings: Codable, Equatable {
    var expandsWhileTyping = false
    var libraryEnabled = false
    var playsSound = false
    var soundName = "Tink"
}

@MainActor
final class SnippetExpander: ObservableObject {
    static let settingsKey = "snippets.settings"
    static let snippetsKey = "snippets.items"
    static let insertDelay: TimeInterval = 0.15
    static let modifierWait: TimeInterval = 1.5
    static let soundsFolder = "/System/Library/Sounds"

    @Published var settings: SnippetSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            apply(previous: oldValue)
        }
    }
    @Published private(set) var snippets: [Snippet] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(snippets), forKey: Self.snippetsKey)
            applyTap()
        }
    }

    private let clipboard: ClipboardViewModel
    private var matcher = SnippetMatcher()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private lazy var library = SnippetLibraryController(expander: self)

    init(clipboard: ClipboardViewModel) {
        self.clipboard = clipboard
        let defaults = UserDefaults.standard
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(SnippetSettings.self, from: $0) } ?? SnippetSettings()
        snippets = defaults.data(forKey: Self.snippetsKey).flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
        KeyboardShortcuts.onKeyUp(for: .snippetLibrary) { [weak self] in
            MainActor.assumeIsolated { self?.library.toggle() }
        }
        observers = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.matcher.reset() }
            }),
            (NotificationCenter.default, NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTap() }
            }),
        ]
        apply(previous: nil)
    }

    var isListening: Bool { tap != nil }

    static var sounds: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: soundsFolder)) ?? [])
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }

    func save(_ snippet: Snippet) {
        let cleaned = snippet.cleaned()
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = cleaned
        } else {
            snippets.append(cleaned)
        }
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
    }

    func setEnabled(_ snippet: Snippet, _ isEnabled: Bool) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index].isEnabled = isEnabled
    }

    func openLibrary() {
        library.toggle()
    }

    func render(_ snippet: Snippet) -> String {
        SnippetTemplate.render(snippet.text, now: Date(), locale: .current, timeZone: .current) {
            NSPasteboard.general.string(forType: .string)
        }
    }

    func insert(_ snippet: Snippet) {
        let isOwnAppInFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard AXIsProcessTrusted() else {
            PasteService.requestAccessibility()
            return NSSound.beep()
        }
        guard !isOwnAppInFront, !IsSecureEventInputEnabled() else { return NSSound.beep() }
        let text = render(snippet)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.insertDelay) {
            PasteService.whenModifiersReleased(timeout: Self.modifierWait) { [weak self] in
                self?.deliver(text, erasing: 0, delimiter: nil)
            }
        }
    }

    private func apply(previous: SnippetSettings?) {
        if previous?.libraryEnabled != settings.libraryEnabled {
            if settings.libraryEnabled { KeyboardShortcuts.enable([.snippetLibrary]) } else { KeyboardShortcuts.disable([.snippetLibrary]) }
        }
        applyTap()
    }

    private func applyTap() {
        let needsTap = settings.expandsWhileTyping && snippets.contains(where: \.isEnabled) && AXIsProcessTrusted()
        guard needsTap != (tap != nil) else { return }
        if needsTap { startTap() } else { stopTap() }
        objectWillChange.send()
    }

    private func startTap() {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let expander = Unmanaged<SnippetExpander>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { expander.handle(type, event) }
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                              callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let loopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = loopSource
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        matcher.reset()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard type == .keyDown else {
            matcher.reset()
            return pass
        }
        guard event.getIntegerValueField(.eventSourceUserData) != SyntheticTyping.marker else { return pass }
        guard !IsSecureEventInputEnabled() else {
            matcher.reset()
            return pass
        }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch SnippetKeys.classify(keyCode: keyCode, flags: event.flags, characters: NSEvent(cgEvent: event)?.characters ?? "") {
        case .reset:
            matcher.reset()
            return pass
        case .backspace:
            matcher.backspace()
            return pass
        case .delimiter:
            defer { matcher.reset() }
            guard let snippet = matcher.match(in: snippets, mode: .afterDelimiter), canType else { return pass }
            expand(snippet, erasing: snippet.trigger.count, delimiter: (keyCode, event.flags))
            return nil
        case .character(let text):
            guard let snippet = matcher.match(in: snippets, mode: .immediately, adding: text), canType else {
                matcher.type(text)
                return pass
            }
            matcher.reset()
            expand(snippet, erasing: snippet.trigger.count - 1, delimiter: nil)
            return nil
        }
    }

    private var canType: Bool {
        InjectionStyle.style(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) != .passthrough
    }

    private func expand(_ snippet: Snippet, erasing count: Int, delimiter: (keyCode: Int, flags: CGEventFlags)?) {
        deliver(render(snippet), erasing: count, delimiter: delimiter)
        if settings.playsSound { NSSound(named: NSSound.Name(settings.soundName))?.play() }
    }

    private func deliver(_ text: String, erasing count: Int, delimiter: (keyCode: Int, flags: CGEventFlags)?) {
        let style = InjectionStyle.style(for: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let pressDelimiter = { if let delimiter { SyntheticTyping.press(delimiter.keyCode, flags: delimiter.flags) } }
        guard text.contains(where: \.isNewline) else {
            SyntheticTyping.send(TypingEdit(backspaces: count, text: text), style: style)
            return pressDelimiter()
        }
        let ending = delimiter.map { SnippetKeys.delimiterText(keyCode: $0.keyCode) } ?? ""
        clipboard.pasteTemporarily(text + ending, beforePaste: {
            if count > 0 { SyntheticTyping.send(TypingEdit(backspaces: count, text: ""), style: style) }
        }, onCancel: pressDelimiter)
    }
}

@MainActor
final class SnippetLibraryModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { selection = 0 } }
    }
    @Published var selection = 0

    let expander: SnippetExpander
    var onInsert: ((Snippet) -> Void)?
    var onClose: (() -> Void)?

    init(expander: SnippetExpander) {
        self.expander = expander
    }

    var sections: [(folder: String, snippets: [Snippet])] { SnippetLibrary.sections(expander.snippets, query: query) }
    var visible: [Snippet] { sections.flatMap(\.snippets) }

    func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let items = visible
        switch PanelKeys.command(keyCode: keyCode, modifiers: modifiers, usedArrows: false, hasPile: false) {
        case .move(let delta):
            selection = items.isEmpty ? 0 : min(max(selection + delta, 0), items.count - 1)
        case .paste:
            if items.indices.contains(selection) { onInsert?(items[selection]) }
        case .pasteNumber(let number):
            if items.indices.contains(number - 1) { onInsert?(items[number - 1]) }
        case .escape:
            onClose?()
        default:
            return false
        }
        return true
    }
}

@MainActor
final class SnippetLibraryController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 460, height: 380)
    static let raise: CGFloat = 0.12

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private let model: SnippetLibraryModel

    init(expander: SnippetExpander) {
        model = SnippetLibraryModel(expander: expander)
        super.init()
        model.onInsert = { [weak self, weak expander] snippet in
            self?.close()
            expander?.insert(snippet)
        }
        model.onClose = { [weak self] in self?.close() }
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        model.query = ""
        model.selection = 0
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: SnippetLibraryView(model: model, expander: model.expander))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(Self.size)
        panel.delegate = self
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.midY - Self.size.height / 2 + visible.height * Self.raise))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window === panel else { return event }
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                return self.model.handle(keyCode: event.keyCode, modifiers: event.modifierFlags) ? nil : event
            }
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        let closing = panel
        panel = nil
        closing?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
