import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum ModifierChoice: String, Codable, CaseIterable, Identifiable {
    case none, shift, control, option, command

    var id: String { rawValue }

    var flag: CGEventFlags? {
        switch self {
        case .none: nil
        case .shift: .maskShift
        case .control: .maskControl
        case .option: .maskAlternate
        case .command: .maskCommand
        }
    }

    var title: String {
        switch self {
        case .none: "Off"
        case .shift: "⇧ Shift"
        case .control: "⌃ Control"
        case .option: "⌥ Option"
        case .command: "⌘ Command"
        }
    }
}

struct KeyStroke: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum MouseButtonAction: String, Codable, CaseIterable, Identifiable {
    case back, forward, missionControl, appExpose, spaceLeft, spaceRight

    static let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .back: "Back"
        case .forward: "Forward"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        case .spaceLeft: "Space on the left"
        case .spaceRight: "Space on the right"
        }
    }

    var keystroke: KeyStroke {
        switch self {
        case .back: KeyStroke(keyCode: CGKeyCode(kVK_ANSI_LeftBracket), flags: .maskCommand)
        case .forward: KeyStroke(keyCode: CGKeyCode(kVK_ANSI_RightBracket), flags: .maskCommand)
        case .missionControl: KeyStroke(keyCode: CGKeyCode(kVK_UpArrow), flags: Self.arrowFlags)
        case .appExpose: KeyStroke(keyCode: CGKeyCode(kVK_DownArrow), flags: Self.arrowFlags)
        case .spaceLeft: KeyStroke(keyCode: CGKeyCode(kVK_LeftArrow), flags: Self.arrowFlags)
        case .spaceRight: KeyStroke(keyCode: CGKeyCode(kVK_RightArrow), flags: Self.arrowFlags)
        }
    }
}

struct InputSettings: Codable, Equatable {
    var wheelPinch = false
    var pinchModifier = ModifierChoice.control
    var invertVertical = false
    var invertHorizontal = false
    var sidewaysModifier = ModifierChoice.none
    var fastModifier = ModifierChoice.none
    var fastMultiplier: Double = 3
    var linearLines = 0
    var smoothScroll = false
    var zoomModifier = ModifierChoice.none
    var buttonActions: [Int: MouseButtonAction] = [:]
    var clickDebounceMs = 0
    var keyDebounceMs = 0
    var quitProtection = QuitGuard.Mode.off
    var closeProtection = QuitGuard.Mode.off
    var focusFollowsMouse = false
    var focusDelayMs = 250
    var raisesOnFocus = true
    var hyperKey = false
    var hyperTapsEscape = false
    var excludedApps: [String] = []

    func action(forButton button: Int) -> MouseButtonAction? {
        buttonActions[button]
    }

    var eventTypes: [CGEventType] {
        var types: [CGEventType] = []
        if invertVertical || invertHorizontal || sidewaysModifier != .none || fastModifier != .none || linearLines > 0 || smoothScroll
            || zoomModifier != .none {
            types.append(.scrollWheel)
        }
        if clickDebounceMs > 0 { types += [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp] }
        if clickDebounceMs > 0 || !buttonActions.isEmpty { types += [.otherMouseDown, .otherMouseUp] }
        if keyDebounceMs > 0 || quitProtection != .off || closeProtection != .off || hyperKey { types += [.keyDown, .keyUp] }
        if focusFollowsMouse { types.append(.mouseMoved) }
        return types
    }
}

extension InputSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = InputSettings()
        wheelPinch = try container.decodeIfPresent(Bool.self, forKey: .wheelPinch) ?? defaults.wheelPinch
        pinchModifier = try container.decodeIfPresent(ModifierChoice.self, forKey: .pinchModifier) ?? defaults.pinchModifier
        invertVertical = try container.decodeIfPresent(Bool.self, forKey: .invertVertical) ?? defaults.invertVertical
        invertHorizontal = try container.decodeIfPresent(Bool.self, forKey: .invertHorizontal) ?? defaults.invertHorizontal
        sidewaysModifier = try container.decodeIfPresent(ModifierChoice.self, forKey: .sidewaysModifier) ?? defaults.sidewaysModifier
        fastModifier = try container.decodeIfPresent(ModifierChoice.self, forKey: .fastModifier) ?? defaults.fastModifier
        fastMultiplier = try container.decodeIfPresent(Double.self, forKey: .fastMultiplier) ?? defaults.fastMultiplier
        linearLines = try container.decodeIfPresent(Int.self, forKey: .linearLines) ?? defaults.linearLines
        smoothScroll = try container.decodeIfPresent(Bool.self, forKey: .smoothScroll) ?? defaults.smoothScroll
        zoomModifier = try container.decodeIfPresent(ModifierChoice.self, forKey: .zoomModifier) ?? defaults.zoomModifier
        buttonActions = try container.decodeIfPresent([Int: MouseButtonAction].self, forKey: .buttonActions) ?? defaults.buttonActions
        clickDebounceMs = try container.decodeIfPresent(Int.self, forKey: .clickDebounceMs) ?? defaults.clickDebounceMs
        keyDebounceMs = try container.decodeIfPresent(Int.self, forKey: .keyDebounceMs) ?? defaults.keyDebounceMs
        quitProtection = try container.decodeIfPresent(QuitGuard.Mode.self, forKey: .quitProtection) ?? defaults.quitProtection
        closeProtection = try container.decodeIfPresent(QuitGuard.Mode.self, forKey: .closeProtection) ?? defaults.closeProtection
        focusFollowsMouse = try container.decodeIfPresent(Bool.self, forKey: .focusFollowsMouse) ?? defaults.focusFollowsMouse
        focusDelayMs = try container.decodeIfPresent(Int.self, forKey: .focusDelayMs) ?? defaults.focusDelayMs
        raisesOnFocus = try container.decodeIfPresent(Bool.self, forKey: .raisesOnFocus) ?? defaults.raisesOnFocus
        hyperKey = try container.decodeIfPresent(Bool.self, forKey: .hyperKey) ?? defaults.hyperKey
        hyperTapsEscape = try container.decodeIfPresent(Bool.self, forKey: .hyperTapsEscape) ?? defaults.hyperTapsEscape
        excludedApps = try container.decodeIfPresent([String].self, forKey: .excludedApps) ?? defaults.excludedApps
    }
}

struct ScrollInput {
    let deltaY: Double
    let deltaX: Double
    let isContinuous: Bool
    let flags: CGEventFlags
}

enum ScrollResult: Equatable {
    case pass
    case scroll(deltaY: Double, deltaX: Double)
    case zoom(zoomIn: Bool)
}

enum ScrollTransform {
    static func apply(_ input: ScrollInput, settings: InputSettings) -> ScrollResult {
        guard !input.isContinuous else { return .pass }
        if let zoom = settings.zoomModifier.flag, input.flags.contains(zoom), input.deltaY != 0 {
            return .zoom(zoomIn: input.deltaY > 0)
        }
        var y = input.deltaY
        var x = input.deltaX
        var changed = false
        if settings.linearLines > 0 {
            let lines = Double(settings.linearLines)
            if y != 0 { y = y > 0 ? lines : -lines }
            if x != 0 { x = x > 0 ? lines : -lines }
            changed = true
        }
        if let sideways = settings.sidewaysModifier.flag, input.flags.contains(sideways), y != 0 {
            x = y
            y = 0
            changed = true
        }
        if let fast = settings.fastModifier.flag, input.flags.contains(fast) {
            y *= settings.fastMultiplier
            x *= settings.fastMultiplier
            changed = true
        }
        if settings.invertVertical, y != 0 {
            y = -y
            changed = true
        }
        if settings.invertHorizontal, x != 0 {
            x = -x
            changed = true
        }
        return changed ? .scroll(deltaY: y, deltaX: x) : .pass
    }
}

struct Debouncer {
    let threshold: TimeInterval
    private var lastUp: [Int: TimeInterval] = [:]

    init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    func shouldDrop(key: Int, isDown: Bool, at time: TimeInterval) -> Bool {
        guard isDown, threshold > 0, let up = lastUp[key] else { return false }
        return time - up < threshold
    }

    mutating func record(key: Int, isDown: Bool, at time: TimeInterval) {
        if !isDown { lastUp[key] = time }
    }
}

struct QuitGuard {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case off, hold, doublePress, shift

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Off"
            case .hold: "Hold the keys"
            case .doublePress: "Press twice"
            case .shift: "Add ⇧ Shift"
            }
        }
    }

    enum Decision: Equatable {
        case allow, wait, cancel, remind
    }

    let mode: Mode
    let hold: TimeInterval
    let window: TimeInterval
    private var pressedAt: TimeInterval?
    private var lastPress: TimeInterval?

    init(mode: Mode, hold: TimeInterval = 0.8, window: TimeInterval = 0.6) {
        self.mode = mode
        self.hold = hold
        self.window = window
    }

    var isWaiting: Bool { pressedAt != nil }

    mutating func keyDown(at time: TimeInterval) -> Decision {
        switch mode {
        case .off:
            return .allow
        case .hold:
            if pressedAt == nil { pressedAt = time }
            return .wait
        case .doublePress:
            if let last = lastPress, time - last <= window {
                lastPress = nil
                return .allow
            }
            lastPress = time
            return .remind
        case .shift:
            return .remind
        }
    }

    mutating func keyUp(at time: TimeInterval) -> Decision {
        guard mode == .hold, pressedAt != nil else { return .allow }
        pressedAt = nil
        return .cancel
    }

    mutating func tick(at time: TimeInterval) -> Decision? {
        guard mode == .hold, let pressedAt, time - pressedAt >= hold else { return nil }
        self.pressedAt = nil
        return .allow
    }
}

struct SmoothScroll {
    let response: Double
    private(set) var remaining: Double = 0

    var isActive: Bool { abs(remaining) >= 0.5 }

    mutating func add(_ pixels: Double) {
        remaining += pixels
    }

    mutating func step() -> Double {
        let delta = remaining * response
        remaining -= delta
        return delta
    }
}

@MainActor
final class InputHUD {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, for seconds: TimeInterval = 1.2, color: NSColor? = nil) {
        let panel = panel ?? makePanel()
        if let color, let font = label?.font {
            let swatch = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color, .font: font])
            swatch.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor, .font: font]))
            label?.attributedStringValue = swatch
        } else {
            label?.stringValue = text
        }
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: max(220, CGFloat(text.count) * 8 + 40), height: 44)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 140, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: effect.centerXAnchor), label.centerYAnchor.constraint(equalTo: effect.centerYAnchor)])
        panel.contentView = effect
        self.label = label
        return panel
    }
}

enum HyperKeyMapping {
    static let capsLock = "0x700000039"
    static let f18 = "0x70000006D"
    static let f18KeyCode = 79

    static let enabledKey = "input.hyperMapped"

    static func restoreIfNeeded() {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        set(false)
    }

    static func set(_ isOn: Bool) {
        UserDefaults.standard.set(isOn, forKey: enabledKey)
        let mapping = isOn ? "[{\"HIDKeyboardModifierMappingSrc\":\(capsLock),\"HIDKeyboardModifierMappingDst\":\(f18)}]" : "[]"
        _ = CommandRunner.run("/usr/bin/hidutil", ["property", "--set", "{\"UserKeyMapping\":\(mapping)}"])
    }
}
