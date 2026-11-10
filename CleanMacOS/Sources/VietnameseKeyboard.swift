import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

struct TypingPreferences: Codable, Equatable {
    var isEnabled = false
    var isVietnamese = true
    var options = TypingOptions()
    var macros: [String: String] = [:]
    var excludedApps: [String] = []
    var appModes: [String: Bool] = [:]
    var remembersAppMode = true

    func mode(for bundleID: String?) -> Bool {
        guard remembersAppMode, let bundleID, let remembered = appModes[bundleID] else { return isVietnamese }
        return remembered
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        bundleID.map(excludedApps.contains) ?? false
    }
}

struct TypingPreferencesStore {
    static let key = "typing.preferences"
    let defaults: UserDefaults

    func load() -> TypingPreferences {
        guard let data = defaults.data(forKey: Self.key) else { return TypingPreferences() }
        return (try? JSONDecoder().decode(TypingPreferences.self, from: data)) ?? TypingPreferences()
    }

    func save(_ preferences: TypingPreferences) {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.key)
    }
}

enum KeyAction: Equatable {
    case pass
    case reset
    case backspace
    case type(Unicode.Scalar)
}

enum KeyClassifier {
    static let resetKeys: Set<Int> = [
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
    ]
    static let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

    static func classify(keyCode: Int, flags: CGEventFlags, characters: [UniChar]) -> KeyAction {
        if !flags.intersection(shortcutFlags).isEmpty || resetKeys.contains(keyCode) { return .reset }
        if keyCode == kVK_Delete { return .backspace }
        guard characters.count == 1, let scalar = Unicode.Scalar(characters[0]), !scalar.properties.isWhitespace || scalar == " ",
              scalar.value >= 0x20, scalar.value != 0x7F else { return .reset }
        return .type(scalar)
    }
}

@MainActor
final class VietnameseKeyboard: ObservableObject {
    static let syntheticMarker: Int64 = 0x4D4B_4954
    static let unicodeChunk = 20

    @Published private(set) var preferences: TypingPreferences
    @Published private(set) var isRunning = false
    @Published private(set) var frontmostApp: NSRunningApplication?

    private let store: TypingPreferencesStore
    private let engine = TypingEngine()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var activation: AnyCancellable?

    init(store: TypingPreferencesStore = TypingPreferencesStore(defaults: .standard)) {
        self.store = store
        preferences = store.load()
        apply()
        activation = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.appChanged(app) }
            }
        frontmostApp = NSWorkspace.shared.frontmostApplication
        if preferences.isEnabled { start() }
    }

    var hasPermission: Bool { AXIsProcessTrusted() }
    var isVietnamese: Bool { preferences.mode(for: frontmostApp?.bundleIdentifier) }

    func update(_ change: (inout TypingPreferences) -> Void) {
        change(&preferences)
        store.save(preferences)
        apply()
        if preferences.isEnabled { start() } else { stop() }
    }

    func toggleMode() {
        let next = !isVietnamese
        update { preferences in
            preferences.isVietnamese = next
            if preferences.remembersAppMode, let bundleID = frontmostApp?.bundleIdentifier {
                preferences.appModes[bundleID] = next
            }
        }
        engine.reset()
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else {
            isRunning = tap != nil
            return
        }
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let keyboard = Unmanaged<VietnameseKeyboard>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { keyboard.handle(type, event) }
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: callback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let loopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = loopSource
        isRunning = true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isRunning = false
        engine.reset()
    }

    private func apply() {
        engine.configure(preferences.options)
        engine.setMacros(preferences.macros)
    }

    private func appChanged(_ app: NSRunningApplication?) {
        frontmostApp = app
        engine.reset()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            break
        default:
            engine.reset()
            return Unmanaged.passUnretained(event)
        }
        let bundleID = frontmostApp?.bundleIdentifier
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker,
              preferences.mode(for: bundleID), !preferences.isExcluded(bundleID) else { return Unmanaged.passUnretained(event) }
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch KeyClassifier.classify(keyCode: keyCode, flags: event.flags, characters: Array(characters.prefix(length))) {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .reset:
            engine.reset()
            return Unmanaged.passUnretained(event)
        case .backspace:
            engine.backspace()
            return Unmanaged.passUnretained(event)
        case .type(let scalar):
            guard let edit = engine.key(scalar) else { return Unmanaged.passUnretained(event) }
            send(edit)
            return nil
        }
    }

    private func send(_ edit: TypingEdit) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<edit.backspaces {
            post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false))
        }
        let units = Array(edit.text.utf16)
        for start in stride(from: 0, to: units.count, by: Self.unicodeChunk) {
            let chunk = Array(units[start..<min(start + Self.unicodeChunk, units.count)])
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(event)
            }
        }
    }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        event.flags = []
        event.post(tap: .cgSessionEventTap)
    }
}
