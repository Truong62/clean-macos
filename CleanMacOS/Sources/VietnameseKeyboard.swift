import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine

struct TypingMacro: Codable, Equatable, Identifiable {
    var id = UUID()
    var trigger: String
    var expansion: String
    var isEnabled = true

    static let starters = [
        TypingMacro(trigger: "vn", expansion: "Việt Nam", isEnabled: false),
        TypingMacro(trigger: "hn", expansion: "Hà Nội", isEnabled: false),
        TypingMacro(trigger: "hcm", expansion: "Hồ Chí Minh", isEnabled: false),
        TypingMacro(trigger: "tphcm", expansion: "Thành phố Hồ Chí Minh", isEnabled: false),
    ]

    static func parse(_ text: String) -> [TypingMacro] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix(";"), let colon = trimmed.firstIndex(of: ":") else { return nil }
            let trigger = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let expansion = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !trigger.isEmpty, !expansion.isEmpty else { return nil }
            return TypingMacro(trigger: trigger, expansion: expansion)
        }
    }

    static func export(_ macros: [TypingMacro]) -> String {
        macros.map { "\($0.trigger):\($0.expansion)" }.joined(separator: "\n") + "\n"
    }
}

struct TypingPreferences: Codable, Equatable {
    var isEnabled = false
    var isVietnamese = true
    var options = TypingOptions()
    var macros = TypingMacro.starters
    var excludedApps: [String] = []
    var appModes: [String: Bool] = [:]
    var remembersAppMode = true
    var escRestores = false
    var playsSound = false

    var activeMacros: [String: String] {
        Dictionary(macros.filter(\.isEnabled).map { ($0.trigger, $0.expansion) }, uniquingKeysWith: { first, _ in first })
    }

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
    case type(Unicode.Scalar)
    case backspace
    case commit
    case escape
    case reset
}

enum KeyClassifier {
    static let commitKeys: Set<Int> = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab]
    static let navigationKeys: Set<Int> = [
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
    ]
    static let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

    static func classify(keyCode: Int, flags: CGEventFlags, characters: [UniChar]) -> KeyAction {
        if !flags.intersection(shortcutFlags).isEmpty || navigationKeys.contains(keyCode) { return .reset }
        if keyCode == kVK_Delete { return .backspace }
        if commitKeys.contains(keyCode) { return .commit }
        if keyCode == kVK_Escape { return .escape }
        guard characters.count == 1, let scalar = Unicode.Scalar(characters[0]), scalar.value >= 0x20, scalar.value != 0x7F,
              !scalar.properties.isWhitespace || scalar == " " else { return .reset }
        return .type(scalar)
    }
}

enum SyntheticKey: Equatable {
    case backspace
    case text(String)
    case pause(UInt32)
}

enum InjectionStyle: Equatable {
    case fast, browser, slow, characterByCharacter, passthrough

    static let autocompleteBreaker = "\u{202F}"
    static let chunkUnits = 20
    static let browsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium", "company.thebrowser.Browser",
        "company.thebrowser.dia", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen",
        "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.duckduckgo.macos.browser",
        "com.apple.Safari", "ai.perplexity.comet", "com.openai.atlas",
    ]
    static let slowApps: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
        "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.Zed", "com.sublimetext.4", "com.panic.Nova", "notion.id", "com.microsoft.Word", "com.microsoft.Excel",
        "com.microsoft.Outlook",
    ]
    static let remoteApps: Set<String> = ["com.teamviewer.TeamViewer", "com.philandro.anydesk", "com.carriez.rustdesk", "com.apple.ScreenContinuity"]

    static func style(for bundleID: String?) -> InjectionStyle {
        guard let bundleID else { return .fast }
        if remoteApps.contains(bundleID) { return .passthrough }
        if browsers.contains(bundleID) { return .browser }
        if slowApps.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.") { return .slow }
        if bundleID.hasPrefix("com.adobe.") { return .characterByCharacter }
        return .fast
    }

    func plan(_ edit: TypingEdit) -> [SyntheticKey] {
        let pauses: (backspace: UInt32, afterBackspaces: UInt32, chunk: UInt32) = switch self {
        case .slow: (8000, 25000, 8000)
        case .browser: (3000, 8000, 3000)
        default: (0, 0, 0)
        }
        var keys: [SyntheticKey] = []
        var backspaces = edit.backspaces
        if self == .browser && backspaces > 0 {
            keys.append(.text(Self.autocompleteBreaker))
            backspaces += 1
        }
        for _ in 0..<backspaces {
            keys.append(.backspace)
            if pauses.backspace > 0 { keys.append(.pause(pauses.backspace)) }
        }
        if backspaces > 0 && pauses.afterBackspaces > 0 { keys.append(.pause(pauses.afterBackspaces)) }
        var chunk = ""
        for character in edit.text {
            if !chunk.isEmpty && (self == .characterByCharacter || chunk.utf16.count + character.utf16.count > Self.chunkUnits) {
                keys.append(.text(chunk))
                if pauses.chunk > 0 { keys.append(.pause(pauses.chunk)) }
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty {
            keys.append(.text(chunk))
            if pauses.chunk > 0 { keys.append(.pause(pauses.chunk)) }
        }
        return keys
    }
}

enum SyntheticTyping {
    static let marker: Int64 = 0x4D4B_4954

    static func send(_ edit: TypingEdit, style: InjectionStyle) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for key in style.plan(edit) {
            switch key {
            case .backspace:
                post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: true))
                post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: false))
            case .text(let text):
                let units = Array(text.utf16)
                for isDown in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    post(event)
                }
            case .pause(let micros):
                usleep(micros)
            }
        }
    }

    static func press(_ keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true), flags: flags)
        post(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false), flags: flags)
    }

    static func post(_ event: CGEvent?, flags: CGEventFlags = []) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }
}

enum InputSourceCheck {
    static let blockedIDs: Set<String> = ["com.apple.keylayout.UnicodeHexInput"]

    static func allowsTyping() -> Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return true }
        let id = string(source, kTISPropertyInputSourceID) ?? ""
        let type = string(source, kTISPropertyInputSourceType) ?? ""
        let ascii = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable)
            .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? true
        return !blockedIDs.contains(id) && type == (kTISTypeKeyboardLayout as String) && ascii
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        TISGetInputSourceProperty(source, key).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }
}

@MainActor
final class VietnameseKeyboard: ObservableObject {
    static let syntheticMarker = SyntheticTyping.marker
    static let watchdogInterval: TimeInterval = 2
    static let otherTypingApps = ["GoNhanh", "Gõ Nhanh", "OpenKey", "EVKey", "UniKey", "Unikey"]
    static let toggleSound = "Tink"

    @Published private(set) var preferences: TypingPreferences
    @Published private(set) var isRunning = false
    @Published private(set) var frontmostApp: NSRunningApplication?
    @Published private(set) var isSecureInput = false
    @Published private(set) var inputSourceAllowed = true
    @Published private(set) var otherTypingApp: String?
    @Published private(set) var hasPermission = AXIsProcessTrusted()

    private let store: TypingPreferencesStore
    private let engine = TypingEngine()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var watchers: [AnyCancellable] = []
    private var watchdog: Timer?
    private var permissionPoll: Timer?

    init(store: TypingPreferencesStore = TypingPreferencesStore(defaults: .standard)) {
        self.store = store
        preferences = store.load()
        frontmostApp = NSWorkspace.shared.frontmostApplication
        configureEngine()
        watchers = [
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification).sink { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.appChanged(app) }
            },
            DistributedNotificationCenter.default()
                .publisher(for: Notification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"))
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshStatus() } },
        ]
        refreshStatus()
        if preferences.isEnabled { start() }
    }

    var isVietnamese: Bool { preferences.mode(for: frontmostApp?.bundleIdentifier) }

    func update(_ change: (inout TypingPreferences) -> Void) {
        change(&preferences)
        store.save(preferences)
        configureEngine()
        if preferences.isEnabled { start() } else { stop() }
    }

    func toggleMode() {
        guard preferences.isEnabled else { return }
        let next = !isVietnamese
        update { preferences in
            preferences.isVietnamese = next
            if preferences.remembersAppMode, let bundleID = frontmostApp?.bundleIdentifier {
                preferences.appModes[bundleID] = next
            }
        }
        if preferences.playsSound { NSSound(named: Self.toggleSound)?.play() }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        refreshStatus()
        guard tap == nil else { return }
        guard hasPermission else {
            isRunning = false
            waitForPermission()
            return
        }
        let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let keyboard = Unmanaged<VietnameseKeyboard>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { keyboard.handle(type, event) }
        }
        let created = [CGEventTapLocation.cghidEventTap, .cgSessionEventTap].lazy.compactMap { location in
            CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                              callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        }.first
        guard let created else { return }
        let loopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = loopSource
        isRunning = true
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTap() }
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        permissionPoll?.invalidate()
        permissionPoll = nil
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

    func refreshStatus() {
        hasPermission = AXIsProcessTrusted()
        isSecureInput = IsSecureEventInputEnabled()
        inputSourceAllowed = InputSourceCheck.allowsTyping()
        otherTypingApp = NSWorkspace.shared.runningApplications
            .compactMap(\.localizedName)
            .first { Self.otherTypingApps.contains($0) }
    }

    private func waitForPermission() {
        guard permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.permissionPoll?.invalidate()
                self.permissionPoll = nil
                if self.preferences.isEnabled { self.start() }
            }
        }
    }

    private func checkTap() {
        refreshStatus()
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func configureEngine() {
        engine.configure(preferences.options, vietnamese: isVietnamese)
        engine.setMacros(preferences.activeMacros)
    }

    private func appChanged(_ app: NSRunningApplication?) {
        frontmostApp = app
        configureEngine()
        refreshStatus()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown:
            break
        default:
            engine.reset()
            return pass
        }
        let bundleID = frontmostApp?.bundleIdentifier
        let style = InjectionStyle.style(for: bundleID)
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticMarker, style != .passthrough,
              !preferences.isExcluded(bundleID), inputSourceAllowed,
              isVietnamese || !preferences.activeMacros.isEmpty else { return pass }
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length, unicodeString: &characters)
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch KeyClassifier.classify(keyCode: keyCode, flags: event.flags, characters: Array(characters.prefix(length))) {
        case .reset:
            engine.reset()
            return pass
        case .backspace:
            engine.backspace()
            return pass
        case .commit:
            return replay(engine.finish(separator: nil), keyCode: keyCode, style: style, event: event)
        case .escape:
            return replay(preferences.escRestores ? engine.restore() : nil, keyCode: keyCode, style: style, event: event)
        case .type(let scalar):
            guard let edit = engine.key(scalar) else { return pass }
            send(edit, style: style)
            return nil
        }
    }

    private func replay(_ edit: TypingEdit?, keyCode: Int, style: InjectionStyle, event: CGEvent) -> Unmanaged<CGEvent>? {
        engine.reset()
        guard let edit else { return Unmanaged.passUnretained(event) }
        send(edit, style: style)
        SyntheticTyping.press(keyCode, flags: event.flags)
        return nil
    }

    private func send(_ edit: TypingEdit, style: InjectionStyle) {
        SyntheticTyping.send(edit, style: style)
    }
}
