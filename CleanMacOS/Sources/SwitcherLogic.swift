import Foundation

struct SwitcherSettings: Codable, Equatable {
    var isEnabled = false
    var dockEnabled = false
    var allWindowsEnabled = false
    var takeover = false
    var layout = SwitcherLayout.previews
    var size = PreviewSize.normal
    var dockSize = PreviewSize.normal
    var placement = SwitcherPlacement.pointer
    var showDelay = 100
    var columns = 0
    var instantSelection = false
    var ignoreHover = false
    var pinSearch = false
    var shortcutHints = false
    var onePerApp = false
    var minimalPreviews = false
    var currentDesktopOnly = false
    var currentDisplayOnly = false
    var hideFullScreen = false
    var hiddenAsMinimized = false
    var minimized = MinimizedOrder.normal
    var windowless = WindowlessApps.off
    var appRules: [String: SwitcherAppRule] = [:]
    var pausedApps: [String] = []
    var dockPausedApps: [String] = []
    var dockCurrentDesktopOnly = false
    var dockDelay = 200
    var dockOpacity = 100
    var dockQuitsApp = false
    var dockCreationOrder = false

    init() {}
}

extension SwitcherSettings {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, dockEnabled, allWindowsEnabled, takeover, layout, size, dockSize, placement, showDelay, columns
        case instantSelection, ignoreHover, pinSearch, shortcutHints, onePerApp, minimalPreviews, currentDesktopOnly, currentDisplayOnly
        case hideFullScreen, hiddenAsMinimized, minimized, windowless, appRules, pausedApps, dockPausedApps
        case dockCurrentDesktopOnly, dockDelay, dockOpacity, dockQuitsApp, dockCreationOrder
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        dockEnabled = try c.decodeIfPresent(Bool.self, forKey: .dockEnabled) ?? dockEnabled
        allWindowsEnabled = try c.decodeIfPresent(Bool.self, forKey: .allWindowsEnabled) ?? allWindowsEnabled
        takeover = try c.decodeIfPresent(Bool.self, forKey: .takeover) ?? takeover
        layout = try c.decodeIfPresent(SwitcherLayout.self, forKey: .layout) ?? layout
        size = try c.decodeIfPresent(PreviewSize.self, forKey: .size) ?? size
        dockSize = try c.decodeIfPresent(PreviewSize.self, forKey: .dockSize) ?? dockSize
        placement = try c.decodeIfPresent(SwitcherPlacement.self, forKey: .placement) ?? placement
        showDelay = min(500, max(0, try c.decodeIfPresent(Int.self, forKey: .showDelay) ?? showDelay))
        columns = min(10, max(0, try c.decodeIfPresent(Int.self, forKey: .columns) ?? columns))
        instantSelection = try c.decodeIfPresent(Bool.self, forKey: .instantSelection) ?? instantSelection
        ignoreHover = try c.decodeIfPresent(Bool.self, forKey: .ignoreHover) ?? ignoreHover
        pinSearch = try c.decodeIfPresent(Bool.self, forKey: .pinSearch) ?? pinSearch
        shortcutHints = try c.decodeIfPresent(Bool.self, forKey: .shortcutHints) ?? shortcutHints
        onePerApp = try c.decodeIfPresent(Bool.self, forKey: .onePerApp) ?? onePerApp
        minimalPreviews = try c.decodeIfPresent(Bool.self, forKey: .minimalPreviews) ?? minimalPreviews
        currentDesktopOnly = try c.decodeIfPresent(Bool.self, forKey: .currentDesktopOnly) ?? currentDesktopOnly
        currentDisplayOnly = try c.decodeIfPresent(Bool.self, forKey: .currentDisplayOnly) ?? currentDisplayOnly
        hideFullScreen = try c.decodeIfPresent(Bool.self, forKey: .hideFullScreen) ?? hideFullScreen
        hiddenAsMinimized = try c.decodeIfPresent(Bool.self, forKey: .hiddenAsMinimized) ?? hiddenAsMinimized
        minimized = try c.decodeIfPresent(MinimizedOrder.self, forKey: .minimized) ?? minimized
        windowless = try c.decodeIfPresent(WindowlessApps.self, forKey: .windowless) ?? windowless
        appRules = try c.decodeIfPresent([String: SwitcherAppRule].self, forKey: .appRules) ?? appRules
        pausedApps = try c.decodeIfPresent([String].self, forKey: .pausedApps) ?? pausedApps
        dockPausedApps = try c.decodeIfPresent([String].self, forKey: .dockPausedApps) ?? dockPausedApps
        dockCurrentDesktopOnly = try c.decodeIfPresent(Bool.self, forKey: .dockCurrentDesktopOnly) ?? dockCurrentDesktopOnly
        dockDelay = min(900, max(200, try c.decodeIfPresent(Int.self, forKey: .dockDelay) ?? dockDelay))
        dockOpacity = min(100, max(40, try c.decodeIfPresent(Int.self, forKey: .dockOpacity) ?? dockOpacity))
        dockQuitsApp = try c.decodeIfPresent(Bool.self, forKey: .dockQuitsApp) ?? dockQuitsApp
        dockCreationOrder = try c.decodeIfPresent(Bool.self, forKey: .dockCreationOrder) ?? dockCreationOrder
    }
}

enum SwitcherLayout: String, Codable, CaseIterable { case previews = "Window previews", icons = "Large icons", list = "Simple list" }
enum SwitcherPlacement: String, Codable, CaseIterable { case pointer = "Pointer’s display", menuBar = "Menu-bar display", frontWindow = "Frontmost window’s display" }
enum PreviewSize: String, Codable, CaseIterable {
    case small = "Small", normal = "Normal", large = "Large", extraLarge = "Extra large"
    var scale: CGFloat {
        switch self { case .small: 0.75; case .normal: 1; case .large: 1.4; case .extraLarge: 1.8 }
    }
    var dockPicture: CGSize {
        let width: CGFloat = self == .small ? 144 : self == .normal ? 200 : self == .large ? 280 : 360
        return CGSize(width: width, height: width * 0.625)
    }
}
enum MinimizedOrder: String, Codable, CaseIterable { case normal = "Normal", last = "Place at end", hide = "Hide" }
enum WindowlessApps: String, Codable, CaseIterable { case off = "Off", finder = "Finder only", all = "All apps" }
enum SwitcherAppRule: String, Codable, CaseIterable { case show = "Show without windows", windows = "Windows only", never = "Never show" }
enum SwitcherMode: Int { case apps, currentApp, allWindows }

struct SwitcherWindow: Identifiable, Equatable {
    let id: String
    let windowID: UInt32?
    let pid: Int32
    let bundleID: String
    let appName: String
    let title: String
    var frame: CGRect
    var zOrder = 0
    var layer = 0
    var alpha: Double = 1
    var minimized = false
    var fullScreen = false
    var hidden = false
    var otherDesktop = false
    var excluded = false
    var axKnown = true
    var axAnswered = true
    var isOnScreen = true
    var isWindowless: Bool { windowID == nil && frame == .zero }
    var displayTitle: String { title.isEmpty ? appName : title }
}

struct SwitcherHistory {
    private(set) var windows: [String] = []
    private(set) var apps: [Int32] = []

    mutating func focus(_ id: String, pid: Int32, source: String? = nil) {
        if let source, source != id { windows.removeAll { $0 == source }; windows.insert(source, at: 0) }
        windows.removeAll { $0 == id }
        windows.insert(id, at: 0)
        windows = Array(windows.prefix(256))
        activate(pid)
    }

    mutating func activate(_ pid: Int32) {
        apps.removeAll { $0 == pid }
        apps.insert(pid, at: 0)
        apps = Array(apps.prefix(256))
    }

    mutating func prune(ids: Set<String>, pids: Set<Int32>) {
        windows.removeAll { !ids.contains($0) }
        apps.removeAll { !pids.contains($0) }
    }

    func ordered(_ candidates: [SwitcherWindow], focused: String?) -> [SwitcherWindow] {
        candidates.sorted { a, b in
            if a.id == focused { return b.id != focused }
            if b.id == focused { return false }
            let ar = windows.firstIndex(of: a.id) ?? Int.max
            let br = windows.firstIndex(of: b.id) ?? Int.max
            if ar != br { return ar < br }
            let ap = apps.firstIndex(of: a.pid) ?? Int.max
            let bp = apps.firstIndex(of: b.pid) ?? Int.max
            if ap != bp { return ap < bp }
            if a.zOrder != b.zOrder { return a.zOrder < b.zOrder }
            return a.id < b.id
        }
    }
}

enum SwitcherFilter {
    static func list(_ candidates: [SwitcherWindow], settings: SwitcherSettings, mode: SwitcherMode, frontPID: Int32?, display: CGRect?,
                     history: SwitcherHistory, focused: String?, dock: Bool = false) -> [SwitcherWindow] {
        var result = history.ordered(candidates.filter { window in
            if mode == .currentApp && window.pid != frontPID { return false }
            if !dock && settings.appRules[window.bundleID] == .never { return false }
            if window.isWindowless {
                guard !dock, mode == .apps, !settings.currentDisplayOnly, settings.appRules[window.bundleID] != .windows else { return false }
                return settings.takeover || settings.appRules[window.bundleID] == .show || settings.windowless == .all
                    || (settings.windowless == .finder && window.bundleID == "com.apple.finder")
            }
            if window.excluded || window.layer != 0 { return false }
            if !window.minimized && (window.frame.width < 80 || window.frame.height < 60) { return false }
            if window.alpha == 0 && !window.minimized && !window.hidden { return false }
            if !window.axKnown && window.axAnswered && !window.otherDesktop && !window.fullScreen && !window.hidden { return false }
            if !window.axKnown && !window.isOnScreen && window.title.isEmpty { return false }
            if dock {
                if settings.dockCurrentDesktopOnly && (window.otherDesktop || window.fullScreen) { return false }
            } else {
                if settings.currentDesktopOnly && window.otherDesktop && !window.fullScreen { return false }
                if settings.hideFullScreen && window.fullScreen { return false }
                if settings.currentDisplayOnly, let display, !display.intersects(window.frame) { return false }
                if settings.minimized == .hide && (window.minimized || (settings.hiddenAsMinimized && window.hidden)) { return false }
            }
            return true
        }, focused: focused)
        if !dock && settings.minimized == .last {
            let minimized: (SwitcherWindow) -> Bool = { $0.minimized || (settings.hiddenAsMinimized && $0.hidden) }
            result = result.filter { !minimized($0) } + result.filter(minimized)
        }
        if !dock && settings.onePerApp && mode == .apps {
            var seen = Set<Int32>()
            result = result.filter { seen.insert($0.pid).inserted }
        }
        if dock {
            result = Array(result.prefix(12))
            return settings.dockCreationOrder ? result.sorted { ($0.windowID ?? 0) < ($1.windowID ?? 0) } : result
        }
        guard result.count > 48 else { return result }
        var retained = Set(result.prefix(2).map(\.id))
        var seen = Set(result.prefix(2).map(\.pid))
        for entry in result where retained.count < 48 {
            if seen.insert(entry.pid).inserted { retained.insert(entry.id) }
        }
        for entry in result where retained.count < 48 { retained.insert(entry.id) }
        return result.filter { retained.contains($0.id) }
    }

    static func search(_ entries: [SwitcherWindow], query: String) -> [SwitcherWindow] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            tokens.allSatisfy { (entry.displayTitle + " " + entry.appName).range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

struct SwitcherSession {
    enum Phase: Equatable { case idle, loading, browsing, commitWhenReady }
    private(set) var phase = Phase.idle
    private(set) var entries: [SwitcherWindow] = []
    private(set) var query = ""
    var selection = 0
    var pinned = false
    private(set) var pendingSteps = 0
    private var reversed = false
    var visible: [SwitcherWindow] { SwitcherFilter.search(entries, query: query) }
    var selected: SwitcherWindow? { visible.indices.contains(selection) ? visible[selection] : nil }

    mutating func begin(reverse: Bool) {
        self = SwitcherSession()
        phase = .loading
        reversed = reverse
    }

    mutating func arrive(_ entries: [SwitcherWindow], frontPID: Int32?, grouped: Bool) -> Bool {
        let commit = phase == .commitWhenReady
        guard phase == .loading || commit else { return false }
        self.entries = entries
        selection = reversed ? max(0, entries.count - 1) : (grouped ? entries.firstIndex { $0.pid != frontPID } ?? 0 : min(1, max(0, entries.count - 1)))
        phase = .browsing
        step(pendingSteps)
        pendingSteps = 0
        return commit
    }

    mutating func release() -> Bool {
        guard !pinned else { return false }
        if phase == .loading { phase = .commitWhenReady; return false }
        return phase == .browsing
    }

    mutating func step(_ delta: Int, repeating: Bool = false) {
        if phase == .loading || phase == .commitWhenReady { pendingSteps = min(64, max(-64, pendingSteps + delta)); return }
        let count = visible.count
        guard count > 0 else { selection = 0; return }
        if repeating { selection = min(count - 1, max(0, selection + delta)) }
        else { selection = ((selection + delta) % count + count) % count }
    }

    mutating func row(_ delta: Int, columns: Int) {
        let count = visible.count
        guard count > 0 else { return }
        let width = max(1, columns)
        let row = selection / width + delta
        guard row >= 0, row <= (count - 1) / width else { return }
        selection = min(count - 1, row * width + selection % width)
    }

    mutating func search(_ text: String) {
        let id = selected?.id
        query = String(text.prefix(64))
        selection = id.flatMap { id in visible.firstIndex { $0.id == id } } ?? min(selection, max(0, visible.count - 1))
    }

    mutating func replace(_ entries: [SwitcherWindow]) {
        let id = selected?.id
        self.entries = entries
        selection = id.flatMap { id in visible.firstIndex { $0.id == id } } ?? min(selection, max(0, visible.count - 1))
    }

    mutating func cancel() { self = SwitcherSession() }
}

struct SwitcherGrid {
    let columns: Int
    let card: CGSize
    let gap: CGFloat
    let padding: CGFloat
    let panel: CGSize

    static func make(count: Int, layout: SwitcherLayout, scale: CGFloat, cap: Int, screen: CGSize) -> Self {
        let scale = max(0.1, scale)
        let card = layout == .previews ? CGSize(width: 288 * scale, height: 214 * scale)
            : CGSize(width: (layout == .icons ? 102 : 132) * min(scale, 1.15), height: layout == .icons ? 112 : 80)
        let gap = 12 * scale
        let padding = 20 * scale
        let width = max(1, screen.width * 0.92)
        let fitting = max(1, Int((width - 2 * padding + gap) / (card.width + gap)))
        let limit = min(fitting, cap > 0 ? max(1, cap) : fitting)
        let count = max(1, count)
        let rows = Int(ceil(Double(count) / Double(limit)))
        let columns = cap > 0 ? min(count, limit) : Int(ceil(Double(count) / Double(rows)))
        let height = CGFloat(rows) * card.height + CGFloat(max(0, rows - 1)) * gap + 2 * padding + 36
        return Self(columns: columns, card: card, gap: gap, padding: padding,
                    panel: CGSize(width: min(width, CGFloat(columns) * (card.width + gap) - gap + 2 * padding), height: min(screen.height * 0.85, height)))
    }
}

enum DockEdge: String, Codable, CaseIterable { case bottom, left, right }
struct DockGeometry {
    var edge: DockEdge = .bottom
    var autoHide = false
    var tileSize: CGFloat = 64
    var magnifiedSize: CGFloat = 128
    var magnification = false
    var hoverSize: CGFloat { min(256, max(16, magnification ? max(tileSize, magnifiedSize) : tileSize)) }

    func inBand(_ point: CGPoint, screen: CGRect) -> Bool {
        guard screen.contains(point) else { return false }
        let band = max(160, hoverSize * 1.5 + 60)
        switch edge {
        case .bottom: return point.y >= screen.maxY - band
        case .left: return point.x <= screen.minX + band
        case .right: return point.x >= screen.maxX - band
        }
    }

    func hit(_ point: CGPoint, dockWindows: [CGRect], dockOwnsElement: Bool) -> Bool {
        dockOwnsElement || dockWindows.contains { $0.insetBy(dx: -8, dy: -8).contains(point) }
    }

    func placement(icon: CGRect, panel: CGSize, visible: CGRect) -> CGRect {
        let gap: CGFloat = autoHide ? 0 : 6
        let size = CGSize(width: min(panel.width, max(1, visible.width - 16)), height: min(panel.height, max(1, visible.height - 16)))
        let origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: icon.midX - size.width / 2, y: icon.minY - gap - size.height)
        case .left: origin = CGPoint(x: icon.maxX + gap, y: icon.midY - size.height / 2)
        case .right: origin = CGPoint(x: icon.minX - gap - size.width, y: icon.midY - size.height / 2)
        }
        return CGRect(x: min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8),
                      y: min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8), width: size.width, height: size.height)
    }

    func panelSize(count: Int, size: PreviewSize, screen: CGSize) -> CGSize {
        let picture = size.dockPicture
        let card = CGSize(width: picture.width + 30, height: picture.height + 66)
        let count = CGFloat(min(12, max(1, count)))
        if edge == .bottom {
            return CGSize(width: min(count * (card.width + 12) + 8, screen.width * 0.9), height: min(card.height + 20, screen.height - 16))
        }
        return CGSize(width: min(card.width + 20, screen.width - 16), height: min(count * (card.height + 12) + 8, screen.height * 0.9))
    }

    func inOpeningPath(_ point: CGPoint, icon: CGRect, panel: CGRect) -> Bool {
        if icon.insetBy(dx: -12, dy: -12).contains(point) || panel.insetBy(dx: -12, dy: -12).contains(point) { return true }
        let bridge: CGRect
        if edge == .bottom {
            bridge = CGRect(x: icon.minX - 12, y: panel.maxY, width: icon.width + 24, height: max(0, icon.minY - panel.maxY))
        } else {
            bridge = CGRect(x: min(icon.maxX, panel.maxX), y: icon.minY - 12,
                            width: max(0, max(icon.minX, panel.minX) - min(icon.maxX, panel.maxX)), height: icon.height + 24)
        }
        return bridge.contains(point)
    }
}

struct DockHoverState {
    private(set) var pid: Int32?
    private(set) var anchor = CGPoint.zero
    private(set) var deadline: TimeInterval?
    private(set) var visiblePID: Int32?
    var enteredPanel = false

    mutating func hover(pid: Int32?, point: CGPoint, now: TimeInterval, delay: TimeInterval) {
        guard let pid else { self.pid = nil; deadline = nil; return }
        if self.pid == pid && hypot(point.x - anchor.x, point.y - anchor.y) <= 6 { return }
        self.pid = pid
        anchor = point
        deadline = now + (visiblePID == nil ? delay : 0.1)
    }

    mutating func open(now: TimeInterval, confirmedPID: Int32?) -> Bool {
        guard let deadline, now >= deadline, let pid, confirmedPID == pid else { return false }
        visiblePID = pid
        self.deadline = nil
        enteredPanel = false
        return true
    }

    mutating func close() { self = Self() }
}

struct ThumbnailPolicy {
    struct Entry { let bytes: Int; var used: TimeInterval; let captured: TimeInterval }
    private(set) var entries: [String: Entry] = [:]
    private(set) var pausedUntil: TimeInterval = 0
    private(set) var backoff: TimeInterval = 30
    private(set) var lastPreflight: TimeInterval = -.infinity
    var bytes: Int { entries.values.reduce(0) { $0 + $1.bytes } }

    mutating func preflight(now: TimeInterval) -> Bool {
        guard now >= pausedUntil, now - lastPreflight >= 5 else { return false }
        lastPreflight = now
        return true
    }

    func canCapture(now: TimeInterval, permission: Bool, active: Bool, simple: Bool, pausedApp: Bool) -> Bool {
        permission && active && !simple && !pausedApp && now >= pausedUntil
    }

    mutating func health(duration: TimeInterval, permissionCheck: Bool, now: TimeInterval) {
        if duration >= (permissionCheck ? 0.5 : 2) {
            pausedUntil = now + backoff
            backoff = min(600, backoff * 2)
        }
    }

    mutating func touch(_ id: String, now: TimeInterval) { entries[id]?.used = now }

    mutating func insert(_ id: String, bytes: Int, now: TimeInterval) -> Set<String> {
        entries[id] = Entry(bytes: max(0, bytes), used: now, captured: now)
        var removed = Set<String>()
        while entries.count > 48 || self.bytes > 64 * 1024 * 1024 {
            guard let oldest = entries.keys.min(by: { a, b in
                let x = entries[a]!.used, y = entries[b]!.used
                return x == y ? a < b : x < y
            }) else { break }
            entries.removeValue(forKey: oldest)
            removed.insert(oldest)
        }
        return removed
    }

    mutating func prune(_ ids: Set<String>) { entries = entries.filter { ids.contains($0.key) } }
    mutating func clear() { entries.removeAll() }
}

struct SwitcherScroll {
    private var remainder: Double = 0
    private var lastTime: TimeInterval = -.infinity

    mutating func steps(x: Double, y: Double, continuous: Bool, momentum: Bool, now: TimeInterval) -> Int {
        guard !momentum else { return 0 }
        let delta = abs(x) > abs(y) ? x : y
        guard delta != 0 else { return 0 }
        if now - lastTime > 0.25 || remainder * delta < 0 { remainder = 0 }
        lastTime = now
        if !continuous { return delta > 0 ? -1 : 1 }
        remainder += delta
        let steps = Int(remainder / 30)
        remainder -= Double(steps) * 30
        return -steps
    }
}


enum MarqueeMotion {
    static func offset(elapsed: TimeInterval, width: CGFloat) -> CGFloat {
        guard elapsed > 0.4, width > 0 else { return 0 }
        return CGFloat((elapsed - 0.4) * 26).truncatingRemainder(dividingBy: width + 20)
    }
}

struct DockInstanceAssignments {
    private(set) var assignments: [String: Int32] = [:]

    mutating func resolve(tiles: [String], processes: [Int32]) -> [String: Int32] {
        let live = Set(processes)
        let tileSet = Set(tiles)
        assignments = assignments.filter { tileSet.contains($0.key) && live.contains($0.value) }
        var used = Set(assignments.values)
        for tile in tiles where assignments[tile] == nil {
            guard let process = processes.first(where: { !used.contains($0) }) else { continue }
            assignments[tile] = process
            used.insert(process)
        }
        return assignments
    }
}
