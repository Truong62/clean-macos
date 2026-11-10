import CoreGraphics
import Foundation

enum RadialGeometry {
    static let deadZone: CGFloat = 40

    static func slice(at point: CGPoint, center: CGPoint, count: Int, deadZone: CGFloat = deadZone) -> Int? {
        guard count > 0 else { return nil }
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        guard hypot(dx, dy) >= Double(deadZone) else { return nil }
        var angle = atan2(dx, dy) * 180 / .pi
        if angle < 0 { angle += 360 }
        let width = 360 / Double(count)
        return Int(((angle + width / 2) / width).rounded(.down)) % count
    }

    static func chipOffset(index: Int, count: Int, radius: CGFloat) -> CGPoint {
        let angle = Double(index) * 2 * .pi / Double(max(count, 1))
        return CGPoint(x: radius * CGFloat(sin(angle)), y: radius * CGFloat(cos(angle)))
    }
}

struct RadialTracker {
    static let movement: CGFloat = 8
    let origin: CGPoint
    private(set) var hasMoved = false

    mutating func highlight(at point: CGPoint, center: CGPoint, count: Int) -> Int? {
        if !hasMoved && hypot(point.x - origin.x, point.y - origin.y) >= Self.movement { hasMoved = true }
        guard hasMoved else { return nil }
        return RadialGeometry.slice(at: point, center: center, count: count)
    }
}

enum GridMove {
    enum Key { case left, right, up, down }

    static func next(from index: Int, key: Key, count: Int, columns: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let target = switch key {
        case .left: index - 1
        case .right: index + 1
        case .up: index - columns
        case .down: index + columns
        }
        if (0..<count).contains(target) { return target }
        if key == .down, index / columns < (count - 1) / columns { return count - 1 }
        return index
    }
}

struct RadialKeystroke: Codable, Equatable, Hashable {
    var keyCode: UInt16 = 128
    var modifiers: UInt64 = 0

    static let modifierMask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue

    static func canPost(heldModifiers: UInt64) -> Bool {
        heldModifiers & modifierMask == 0
    }
}

struct RadialSlice: Codable, Identifiable, Equatable {
    enum Action: Codable, Equatable {
        case command(String)
        case app(String)
        case folder(String)
        case link(String)
        case media(Int)
        case keystroke(RadialKeystroke)
        case toggle(String)
        case window(WindowAction)
        case submenu([RadialSlice])
    }

    var id = UUID()
    var title: String
    var symbol: String
    var action: Action
}

enum RadialAccent: String, Codable, CaseIterable, Identifiable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, gray
    var id: String { rawValue }
}

struct RadialWheel: Codable, Equatable, Identifiable {
    static let originalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id = UUID()
    var name = "Wheel"
    var accent = RadialAccent.blue
    var keyboardEnabled = false
    var mouseButton: Int?
    var slices: [RadialSlice] = []

    init(id: UUID = UUID(), name: String = "Wheel", accent: RadialAccent = .blue, keyboardEnabled: Bool = false,
         mouseButton: Int? = nil, slices: [RadialSlice] = []) {
        self.id = id
        self.name = name
        self.accent = accent
        self.keyboardEnabled = keyboardEnabled
        self.mouseButton = mouseButton.flatMap { (3...31).contains($0) ? $0 : nil }
        self.slices = RadialAvailability.limited(slices)
    }

    private enum CodingKeys: String, CodingKey { case id, name, accent, keyboardEnabled, mouseButton, slices }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? "Wheel",
                  accent: try values.decodeIfPresent(RadialAccent.self, forKey: .accent) ?? .blue,
                  keyboardEnabled: try values.decodeIfPresent(Bool.self, forKey: .keyboardEnabled) ?? false,
                  mouseButton: try values.decodeIfPresent(Int.self, forKey: .mouseButton),
                  slices: try values.decodeIfPresent([RadialSlice].self, forKey: .slices) ?? [])
    }
}

struct RadialSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case pressOrHold, press, hold
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pressOrHold: "Press or hold"
            case .press: "Press"
            case .hold: "Hold"
            }
        }
    }

    enum Preset: String, CaseIterable, Identifiable {
        case general = "General", media = "Media", tools = "Tools", windows = "Window layout", toggles = "Quick toggles", blank = "Blank"
        var id: String { rawValue }
        func wheel() -> RadialWheel {
            let slices: [RadialSlice]
            switch self {
            case .general: slices = RadialSettings.general
            case .media: slices = RadialSettings.media
            case .tools:
                slices = [RadialSlice(title: "Grab Text", symbol: "text.viewfinder", action: .command("grabText")),
                          RadialSlice(title: "Color Picker", symbol: "eyedropper", action: .command("pickColor")),
                          RadialSlice(title: "Clipboard", symbol: "doc.on.clipboard", action: .command("clipboardHistory")),
                          RadialSlice(title: "Scratchpad", symbol: "note.text", action: .command("scratchpad"))]
            case .windows:
                slices = [WindowAction.maximize, .rightHalf, .bottomHalf, .leftHalf, .topHalf, .restore].map {
                    RadialSlice(title: $0.title, symbol: $0.icon, action: .window($0))
                }
            case .toggles:
                slices = [RadialSlice(title: "Dark Mode", symbol: "circle.lefthalf.filled", action: .toggle("darkMode")),
                          RadialSlice(title: "Keep Awake", symbol: "cup.and.saucer.fill", action: .toggle("keepAwake")),
                          RadialSlice(title: "Mute Mics", symbol: "mic.slash.fill", action: .toggle("micMute")),
                          RadialSlice(title: "Hidden Files", symbol: "eye", action: .toggle("hiddenFiles")),
                          RadialSlice(title: "Desktop Icons", symbol: "menubar.dock.rectangle", action: .toggle("desktopIcons"))]
            case .blank: slices = []
            }
            return RadialWheel(name: rawValue, slices: slices.map { slice in
                var copy = slice
                copy.id = UUID()
                return copy
            })
        }
    }

    static let maxSlices = 12
    static let mediaPlay = 16
    static let mediaNext = 17
    static let mediaPrevious = 18
    static let general = [
        RadialSlice(title: "Play/Pause", symbol: "playpause.fill", action: .media(mediaPlay)),
        RadialSlice(title: "Next", symbol: "forward.fill", action: .media(mediaNext)),
        RadialSlice(title: "Screenshot", symbol: "text.viewfinder", action: .command("grabText")),
        RadialSlice(title: "Downloads", symbol: "arrow.down.circle", action: .folder("~/Downloads")),
        RadialSlice(title: "Color Picker", symbol: "eyedropper", action: .command("pickColor")),
        RadialSlice(title: "Previous", symbol: "backward.fill", action: .media(mediaPrevious)),
    ]
    static let media = [
        RadialSlice(title: "Play/Pause", symbol: "playpause.fill", action: .media(mediaPlay)),
        RadialSlice(title: "Next", symbol: "forward.fill", action: .media(mediaNext)),
        RadialSlice(title: "Switch Output", symbol: "hifispeaker.2.fill", action: .command("cycleOutput")),
        RadialSlice(title: "Mute Mics", symbol: "mic.slash.fill", action: .command("micMute")),
        RadialSlice(title: "Previous", symbol: "backward.fill", action: .media(mediaPrevious)),
    ]

    var isEnabled = false
    var mode = Mode.pressOrHold
    var opensAtPointer = true
    var wheels = [RadialWheel(id: RadialWheel.originalID, name: "General", slices: general)]

    init() {}

    private enum CodingKeys: String, CodingKey { case isEnabled, mode, opensAtPointer, wheels, mouseButton, slices }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .pressOrHold
        opensAtPointer = try values.decodeIfPresent(Bool.self, forKey: .opensAtPointer) ?? true
        if let decoded = try values.decodeIfPresent([RadialWheel].self, forKey: .wheels) {
            var seen = Set<UUID>()
            wheels = decoded.map { wheel in
                var result = wheel
                if !seen.insert(wheel.id).inserted { result.id = UUID(); seen.insert(result.id) }
                return result
            }
        } else {
            wheels = [RadialWheel(id: RadialWheel.originalID, name: "General", keyboardEnabled: isEnabled,
                                  mouseButton: try values.decodeIfPresent(Int.self, forKey: .mouseButton),
                                  slices: try values.decodeIfPresent([RadialSlice].self, forKey: .slices) ?? Self.general)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(mode, forKey: .mode)
        try values.encode(opensAtPointer, forKey: .opensAtPointer)
        try values.encode(wheels, forKey: .wheels)
    }
}

enum RadialAvailability {
    static func canRun(_ action: RadialSlice.Action, commandIDs: Set<String>, toggleIDs: Set<String>,
                       hasWindow: Bool, pathExists: (String) -> Bool) -> Bool {
        switch action {
        case .command(let id): commandIDs.contains(id)
        case .toggle(let id): toggleIDs.contains(id)
        case .app(let path): !path.isEmpty && path.lowercased().hasSuffix(".app") && pathExists(path)
        case .folder(let path): !path.isEmpty && pathExists(path)
        case .link(let text):
            !text.contains(where: \.isWhitespace) && URL(string: text)?.scheme != nil
        case .media(let code): [0, 1, 7, 16, 17, 18].contains(code)
        case .keystroke(let stroke): stroke.keyCode <= 127 && stroke.modifiers & ~RadialKeystroke.modifierMask == 0
        case .window: hasWindow
        case .submenu: false
        }
    }

    static func limited(_ slices: [RadialSlice], allowsSubmenu: Bool = true) -> [RadialSlice] {
        slices.prefix(RadialSettings.maxSlices).compactMap { slice in
            guard case .submenu(let children) = slice.action else { return slice }
            guard allowsSubmenu else { return nil }
            var result = slice
            result.action = .submenu(limited(children, allowsSubmenu: false))
            return result
        }
    }

    static func visible(_ slices: [RadialSlice], canRun: (RadialSlice.Action) -> Bool) -> [RadialSlice] {
        limited(slices).compactMap { slice in
            if case .submenu(let children) = slice.action {
                let visibleChildren = children.filter { canRun($0.action) }
                guard !visibleChildren.isEmpty else { return nil }
                var result = slice
                result.action = .submenu(visibleChildren)
                return result
            }
            return canRun(slice.action) ? slice : nil
        }
    }
}

struct RadialNavigation: Equatable {
    private(set) var root: [RadialSlice] = []
    private(set) var submenu: RadialSlice?
    private(set) var isOpen = false
    var slices: [RadialSlice] {
        if case .submenu(let children) = submenu?.action { return children }
        return root
    }

    @discardableResult mutating func open(_ slices: [RadialSlice]) -> Bool {
        root = RadialAvailability.limited(slices)
        submenu = nil
        isOpen = !root.isEmpty
        return isOpen
    }

    mutating func select(_ index: Int) -> RadialSlice.Action? {
        guard isOpen, slices.indices.contains(index) else { return nil }
        let slice = slices[index]
        if case .submenu(let children) = slice.action {
            guard submenu == nil, !children.isEmpty else { return nil }
            submenu = slice
            return nil
        }
        close()
        return slice.action
    }

    mutating func back() {
        if submenu != nil { submenu = nil } else { close() }
    }

    mutating func close() { isOpen = false; submenu = nil; root = [] }
}

enum RadialSelection {
    static func rotate(_ selection: Int?, by offset: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let start = selection ?? (offset < 0 ? 0 : -1)
        return ((start + offset) % count + count) % count
    }

    static func digit(_ digit: Int, count: Int) -> Int? {
        (1...9).contains(digit) && digit <= count ? digit - 1 : nil
    }
}

struct RadialTrigger: Equatable {
    var wheelID: UUID
    var shortcut: RadialKeystroke?
    var mouseButton: Int?
}

struct RadialTriggerConflict: Equatable {
    var first: UUID
    var second: UUID
    var keyboard: Bool
}

enum RadialTriggers {
    static func enabledKeyboardWheels(_ triggers: [RadialTrigger], isEnabled: Bool) -> Set<UUID> {
        guard isEnabled else { return [] }
        let blocked = Set(conflicts(triggers).filter(\.keyboard).flatMap { [$0.first, $0.second] })
        return Set(triggers.filter { $0.shortcut != nil && !blocked.contains($0.wheelID) }.map(\.wheelID))
    }

    static func conflicts(_ triggers: [RadialTrigger]) -> [RadialTriggerConflict] {
        var result: [RadialTriggerConflict] = []
        for (index, first) in triggers.enumerated() {
            for second in triggers.dropFirst(index + 1) {
                if let shortcut = first.shortcut, shortcut == second.shortcut {
                    result.append(RadialTriggerConflict(first: first.wheelID, second: second.wheelID, keyboard: true))
                }
                if let button = first.mouseButton, (3...31).contains(button), button == second.mouseButton {
                    result.append(RadialTriggerConflict(first: first.wheelID, second: second.wheelID, keyboard: false))
                }
            }
        }
        return result
    }
}

struct RadialMousePresses {
    enum Result: Equatable {
        case pass, swallow, press(UUID), release(UUID)
    }

    private var owners: [Int: UUID] = [:]
    var hasPendingRelease: Bool { !owners.isEmpty }

    mutating func handle(button: Int, isDown: Bool, triggers: [RadialTrigger], isEnabled: Bool) -> Result {
        if !isDown {
            guard let owner = owners.removeValue(forKey: button) else { return .pass }
            return .release(owner)
        }
        if owners[button] != nil { return .swallow }
        let matching = triggers.filter { $0.mouseButton == button }
        guard isEnabled, (3...31).contains(button), matching.count == 1, let owner = matching.first?.wheelID else { return .pass }
        owners[button] = owner
        return .press(owner)
    }
}

enum QuickPanelEdits {
    static func normalized(_ tiles: [String]) -> [String] {
        var seen = Set<String>()
        return tiles.filter { seen.insert($0).inserted }
    }

    static func hide(_ id: String, in tiles: [String]) -> [String] { tiles.filter { $0 != id } }

    static func add(_ id: String, to tiles: [String], available: Set<String>) -> [String] {
        guard available.contains(id), !tiles.contains(id) else { return tiles }
        return tiles + [id]
    }

    static func move(_ id: String, to target: Int, in tiles: [String]) -> [String] {
        guard let index = tiles.firstIndex(of: id), tiles.indices.contains(target) else { return tiles }
        var result = tiles
        result.insert(result.remove(at: index), at: target)
        return result
    }
}
