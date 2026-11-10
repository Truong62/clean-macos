import AppKit
import ApplicationServices
import KeyboardShortcuts

enum WindowAction: String, CaseIterable, Codable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case maximize, center, nextDisplay, previousDisplay, restore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"
        case .lastTwoThirds: "Last Two Thirds"
        case .maximize: "Maximize"
        case .center: "Center"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        case .restore: "Restore"
        }
    }

    var icon: String {
        switch self {
        case .leftHalf: "rectangle.lefthalf.filled"
        case .rightHalf: "rectangle.righthalf.filled"
        case .topHalf: "rectangle.tophalf.filled"
        case .bottomHalf: "rectangle.bottomhalf.filled"
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        case .firstThird, .centerThird, .lastThird: "rectangle.split.3x1"
        case .firstTwoThirds, .lastTwoThirds: "rectangle.split.2x1"
        case .maximize: "rectangle.fill"
        case .center: "rectangle.center.inset.filled"
        case .nextDisplay: "rectangle.portrait.and.arrow.right"
        case .previousDisplay: "rectangle.portrait.and.arrow.forward"
        case .restore: "arrow.uturn.backward"
        }
    }

    var shortcut: KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("window.\(rawValue)", default: defaultShortcut)
    }

    private var defaultShortcut: KeyboardShortcuts.Shortcut? {
        let keys: [WindowAction: KeyboardShortcuts.Key] = [
            .leftHalf: .leftArrow, .rightHalf: .rightArrow, .topHalf: .upArrow, .bottomHalf: .downArrow, .topLeft: .u, .topRight: .i,
            .bottomLeft: .j, .bottomRight: .k, .firstThird: .d, .centerThird: .f, .lastThird: .g, .firstTwoThirds: .e,
            .lastTwoThirds: .t, .maximize: .return, .center: .c, .restore: .delete,
        ]
        if let key = keys[self] { return .init(key, modifiers: [.control, .option]) }
        return switch self {
        case .nextDisplay: .init(.rightArrow, modifiers: [.control, .option, .command])
        case .previousDisplay: .init(.leftArrow, modifiers: [.control, .option, .command])
        default: nil
        }
    }

    fileprivate var fractions: (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>)? {
        switch self {
        case .leftHalf: (0...0.5, 0...1)
        case .rightHalf: (0.5...1, 0...1)
        case .topHalf: (0...1, 0...0.5)
        case .bottomHalf: (0...1, 0.5...1)
        case .topLeft: (0...0.5, 0...0.5)
        case .topRight: (0.5...1, 0...0.5)
        case .bottomLeft: (0...0.5, 0.5...1)
        case .bottomRight: (0.5...1, 0.5...1)
        case .firstThird: (0...1.0 / 3, 0...1)
        case .centerThird: (1.0 / 3...2.0 / 3, 0...1)
        case .lastThird: (2.0 / 3...1, 0...1)
        case .firstTwoThirds: (0...2.0 / 3, 0...1)
        case .lastTwoThirds: (1.0 / 3...1, 0...1)
        case .maximize: (0...1, 0...1)
        default: nil
        }
    }

    fileprivate var isThird: Bool {
        [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds].contains(self)
    }
}

enum WindowGeometry {
    static let edgeTolerance: CGFloat = 4
    static let cornerSize: CGFloat = 40
    static let cycleWidths: [CGFloat] = [0.5, 2.0 / 3, 1.0 / 3]
    static let matchTolerance: CGFloat = 2

    static func frame(for action: WindowAction, screen: CGRect, window: CGRect, gap: CGFloat) -> CGRect? {
        if action == .center {
            let width = min(window.width, screen.width)
            let height = min(window.height, screen.height)
            return CGRect(x: screen.minX + (screen.width - width) / 2, y: screen.minY + (screen.height - height) / 2, width: width, height: height)
        }
        guard var fractions = action.fractions else { return nil }
        if action.isThird && screen.height > screen.width {
            fractions = (0...1, fractions.x)
        }
        return region(screen, x: fractions.x, y: fractions.y, gap: gap)
    }

    static func cycled(_ action: WindowAction, current: CGRect, screen: CGRect, gap: CGFloat) -> CGRect? {
        guard let base = frame(for: action, screen: screen, window: current, gap: gap) else { return nil }
        guard action == .leftHalf || action == .rightHalf else { return base }
        let sizes = cycleWidths.map { width -> CGRect in
            let range: ClosedRange<CGFloat> = action == .leftHalf ? 0...width : (1 - width)...1
            return region(screen, x: range, y: 0...1, gap: gap)
        }
        guard let index = sizes.firstIndex(where: { matches($0, current) }) else { return base }
        return sizes[(index + 1) % sizes.count]
    }

    static func move(_ window: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let x = (window.minX - source.minX) / source.width
        let y = (window.minY - source.minY) / source.height
        let width = min(window.width / source.width, 1)
        let height = min(window.height / source.height, 1)
        return CGRect(x: target.minX + x * target.width, y: target.minY + y * target.height, width: width * target.width, height: height * target.height)
    }

    static func screenIndex(for window: CGRect, screens: [CGRect]) -> Int? {
        let overlaps = screens.map { screen -> CGFloat in
            let shared = screen.intersection(window)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }) else { return nil }
        if overlaps[best] > 0 { return best }
        let center = CGPoint(x: window.midX, y: window.midY)
        return screens.indices.min { distance(center, screens[$0]) < distance(center, screens[$1]) }
    }

    static func snapAction(cursor: CGPoint, screen: CGRect) -> WindowAction? {
        let left = cursor.x - screen.minX <= edgeTolerance
        let right = screen.maxX - cursor.x <= edgeTolerance
        let top = cursor.y - screen.minY <= edgeTolerance
        let bottom = screen.maxY - cursor.y <= edgeTolerance
        let nearTop = cursor.y - screen.minY <= cornerSize
        let nearBottom = screen.maxY - cursor.y <= cornerSize
        let nearLeft = cursor.x - screen.minX <= cornerSize
        let nearRight = screen.maxX - cursor.x <= cornerSize
        if (left && nearTop) || (top && nearLeft) { return .topLeft }
        if (right && nearTop) || (top && nearRight) { return .topRight }
        if (left && nearBottom) || (bottom && nearLeft) { return .bottomLeft }
        if (right && nearBottom) || (bottom && nearRight) { return .bottomRight }
        if left { return .leftHalf }
        if right { return .rightHalf }
        if top { return .maximize }
        if bottom { return .bottomHalf }
        return nil
    }

    private static func region(_ screen: CGRect, x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, gap: CGFloat) -> CGRect {
        let inner = screen.insetBy(dx: gap, dy: gap)
        var minX = inner.minX + x.lowerBound * inner.width
        var maxX = inner.minX + x.upperBound * inner.width
        var minY = inner.minY + y.lowerBound * inner.height
        var maxY = inner.minY + y.upperBound * inner.height
        if x.lowerBound > 0 { minX += gap / 2 }
        if x.upperBound < 1 { maxX -= gap / 2 }
        if y.lowerBound > 0 { minY += gap / 2 }
        if y.upperBound < 1 { maxY -= gap / 2 }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func matches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= matchTolerance && abs(lhs.minY - rhs.minY) <= matchTolerance
            && abs(lhs.width - rhs.width) <= matchTolerance && abs(lhs.height - rhs.height) <= matchTolerance
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }
}

enum AXWindow {
    static func focused() -> AXUIElement? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return value(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }

    static func at(_ point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element else { return nil }
        if role(element) == kAXWindowRole { return element }
        return value(element, kAXWindowAttribute)
    }

    static func frame(_ window: AXUIElement) -> CGRect? {
        guard let position: AXValue = value(window, kAXPositionAttribute), let size: AXValue = value(window, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    static func setFrame(_ rect: CGRect, of window: AXUIElement) {
        var point = rect.origin
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &point), let extent = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
    }

    static func role(_ element: AXUIElement) -> String? {
        value(element, kAXRoleAttribute)
    }

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    static func screens() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            return CGRect(x: visible.minX, y: primaryHeight - visible.maxY, width: visible.width, height: visible.height)
        }
    }

    static func toAX(_ point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }
}

@MainActor
final class WindowManager: ObservableObject {
    struct Settings: Codable, Equatable {
        var shortcutsEnabled = false
        var gap: Double = 0
        var cyclesOnRepeat = true
        var snapsToEdges = false
        var dragsWithModifiers = false
        var greenButtonMaximizes = false
        var quitsOnLastWindow = false
        var quitExceptions = ["com.apple.finder"]
        var dockClick = DockClickAction.none
        var fixedSpaceOrder = false
    }

    static let settingsKey = "windows.settings"

    @Published var settings: Settings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            applySettings(previous: oldValue)
        }
    }

    private var restoreFrames: [String: CGRect] = [:]
    let mouse = WindowMouseHandler()
    let closer = LastWindowQuitter()

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
        for action in WindowAction.allCases {
            KeyboardShortcuts.onKeyUp(for: action.shortcut) { [weak self] in
                MainActor.assumeIsolated { self?.perform(action) }
            }
        }
        mouse.manager = self
        applySettings(previous: nil)
    }

    func perform(_ action: WindowAction, window explicit: AXUIElement? = nil) {
        guard let window = explicit ?? AXWindow.focused(), let current = AXWindow.frame(window) else { return }
        let screens = AXWindow.screens()
        guard let index = WindowGeometry.screenIndex(for: current, screens: screens) else { return }
        let key = Self.key(for: window)
        let gap = CGFloat(settings.gap)
        let target: CGRect?
        switch action {
        case .restore:
            target = restoreFrames.removeValue(forKey: key)
        case .nextDisplay, .previousDisplay:
            guard screens.count > 1 else { return }
            let next = (index + (action == .nextDisplay ? 1 : screens.count - 1)) % screens.count
            target = WindowGeometry.move(current, from: screens[index], to: screens[next])
        default:
            target = settings.cyclesOnRepeat
                ? WindowGeometry.cycled(action, current: current, screen: screens[index], gap: gap)
                : WindowGeometry.frame(for: action, screen: screens[index], window: current, gap: gap)
        }
        guard let target else { return }
        if action != .restore, restoreFrames[key] == nil { restoreFrames[key] = current }
        AXWindow.setFrame(target, of: window)
    }

    private static func key(for window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return "\(pid)-\(CFHash(window))"
    }

    private func applySettings(previous: Settings?) {
        let names = WindowAction.allCases.map(\.shortcut)
        if settings.shortcutsEnabled { KeyboardShortcuts.enable(names) } else { KeyboardShortcuts.disable(names) }
        mouse.update(settings)
        closer.update(enabled: settings.quitsOnLastWindow, exceptions: Set(settings.quitExceptions))
        if let previous, previous.fixedSpaceOrder != settings.fixedSpaceOrder {
            SpaceOrder.setFixed(settings.fixedSpaceOrder)
        }
    }
}

enum DockClickAction: String, Codable, CaseIterable, Identifiable {
    case none, minimize, hide, cycle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Do nothing extra"
        case .minimize: "Minimize its windows"
        case .hide: "Hide the app"
        case .cycle: "Cycle through its windows"
        }
    }
}

enum SpaceOrder {
    static func setFixed(_ isFixed: Bool) {
        _ = CommandRunner.run("/usr/bin/defaults", ["write", "com.apple.dock", "mru-spaces", "-bool", isFixed ? "false" : "true"])
        _ = CommandRunner.run("/usr/bin/killall", ["Dock"])
    }
}
