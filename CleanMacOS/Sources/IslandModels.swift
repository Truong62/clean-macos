import Foundation

enum IslandDisplayChoice: String, Codable, CaseIterable { case automatic, builtIn, main, pointer, all }
enum IslandOpening: String, Codable, CaseIterable { case click, preview, hover, hidden }
enum IslandSize: String, Codable, CaseIterable { case compact, spacious, custom }
enum IslandSection: String, Codable, CaseIterable, Identifiable {
    case home, mixer, music, clipboard, captures, files, system, tools, calendar, timer, camera, downloads, scratchpad, agents
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mixer: return "Per-app Mixer"
        case .captures: return "Captures"
        case .system: return "System monitor"
        case .tools: return "Tools launcher"
        case .home: return "Home controls"
        case .music: return "Now Playing"
        case .files: return "Files shelf"
        case .camera: return "Camera mirror"
        case .agents: return "AI agents"
        default: return rawValue.capitalized
        }
    }
    var icon: String {
        switch self {
        case .mixer: return "slider.horizontal.3"
        case .captures: return "viewfinder"
        case .system: return "chart.xyaxis.line"
        case .tools: return "wrench.and.screwdriver"
        case .home: return "switch.2"
        case .music: return "music.note"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "tray.full"
        case .calendar: return "calendar"
        case .timer: return "timer"
        case .camera: return "web.camera"
        case .downloads: return "arrow.down.circle"
        case .scratchpad: return "note.text"
        case .agents: return "sparkles"
        }
    }
    var letter: String {
        switch self {
        case .mixer: return "v"
        case .captures: return "s"
        case .system: return "i"
        case .tools: return "t"
        case .home: return "c"
        case .music: return "m"
        case .clipboard: return "b"
        case .files: return "f"
        case .calendar: return "a"
        case .timer: return "r"
        case .camera: return "w"
        case .downloads: return "d"
        case .scratchpad: return "p"
        case .agents: return "g"
        }
    }
}

struct IslandSettings: Codable, Equatable {
    var isEnabled = false
    var shortcut = false
    var display = IslandDisplayChoice.automatic
    var opening = IslandOpening.click
    var size = IslandSize.spacious
    var sections: [IslandSection] = []
    var customWidth = 440.0
    var customHeight = 480.0
    var activationDelay = 0.25
    var closingDelay = 0.18
    var simulatedNotch = false
    var notchWidth = 0.0
    var notchHeight = 0.0
    var capsuleWidth = 0.0
    var capsuleHeight = 0.0
    var capsuleDrop = 0.0
    var noGap = false
    var outline = false
    var includeInCaptures = false
    var hideInFullScreen = false
    var fullScreenHover = false
    var gestures = false
    var haptics = false
    var levelNotices = false
    var batteryNotices = false
    var bluetoothNotices = false
    var calendarCountdown = false
    var timerSound = false
    var timerMinutes = 15
    init() {}
}

extension IslandSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        shortcut = try c.decodeIfPresent(Bool.self, forKey: .shortcut) ?? false
        display = try c.decodeIfPresent(IslandDisplayChoice.self, forKey: .display) ?? .automatic
        opening = try c.decodeIfPresent(IslandOpening.self, forKey: .opening) ?? .click
        size = try c.decodeIfPresent(IslandSize.self, forKey: .size) ?? .spacious
        var seen = Set<IslandSection>()
        sections = (try c.decodeIfPresent([IslandSection].self, forKey: .sections) ?? []).filter { seen.insert($0).inserted }
        customWidth = min(600, max(360, try c.decodeIfPresent(Double.self, forKey: .customWidth) ?? 440))
        customHeight = min(640, max(260, try c.decodeIfPresent(Double.self, forKey: .customHeight) ?? 480))
        activationDelay = min(1, max(0.1, try c.decodeIfPresent(Double.self, forKey: .activationDelay) ?? 0.25))
        closingDelay = min(2, max(0.1, try c.decodeIfPresent(Double.self, forKey: .closingDelay) ?? 0.18))
        simulatedNotch = try c.decodeIfPresent(Bool.self, forKey: .simulatedNotch) ?? false
        notchWidth = min(10, max(-10, try c.decodeIfPresent(Double.self, forKey: .notchWidth) ?? 0))
        notchHeight = min(6, max(-6, try c.decodeIfPresent(Double.self, forKey: .notchHeight) ?? 0))
        capsuleWidth = min(40, max(-40, try c.decodeIfPresent(Double.self, forKey: .capsuleWidth) ?? 0))
        capsuleHeight = min(4, max(-4, try c.decodeIfPresent(Double.self, forKey: .capsuleHeight) ?? 0))
        capsuleDrop = min(20, max(0, try c.decodeIfPresent(Double.self, forKey: .capsuleDrop) ?? 0))
        noGap = try c.decodeIfPresent(Bool.self, forKey: .noGap) ?? false
        outline = try c.decodeIfPresent(Bool.self, forKey: .outline) ?? false
        includeInCaptures = try c.decodeIfPresent(Bool.self, forKey: .includeInCaptures) ?? false
        hideInFullScreen = try c.decodeIfPresent(Bool.self, forKey: .hideInFullScreen) ?? false
        fullScreenHover = try c.decodeIfPresent(Bool.self, forKey: .fullScreenHover) ?? false
        gestures = try c.decodeIfPresent(Bool.self, forKey: .gestures) ?? false
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? false
        levelNotices = try c.decodeIfPresent(Bool.self, forKey: .levelNotices) ?? false
        batteryNotices = try c.decodeIfPresent(Bool.self, forKey: .batteryNotices) ?? false
        bluetoothNotices = try c.decodeIfPresent(Bool.self, forKey: .bluetoothNotices) ?? false
        calendarCountdown = try c.decodeIfPresent(Bool.self, forKey: .calendarCountdown) ?? false
        timerSound = try c.decodeIfPresent(Bool.self, forKey: .timerSound) ?? false
        timerMinutes = min(180, max(1, try c.decodeIfPresent(Int.self, forKey: .timerMinutes) ?? 15))
    }
}

struct IslandDisplay: Equatable {
    var id: UInt32
    var frame: CGRect
    var visibleFrame: CGRect
    var scale: Double
    var safeTop: Double
    var leftArea: CGRect?
    var rightArea: CGRect?
    var builtIn: Bool
    var menuHeight: Double {
        let value = frame.maxY - visibleFrame.maxY
        return (16...64).contains(value) ? value : 24
    }
    var camera: CGSize? {
        guard let leftArea, let rightArea, safeTop > 0, rightArea.minX > leftArea.maxX else { return nil }
        return CGSize(width: min(rightArea.minX - leftArea.maxX, frame.width * 0.7), height: min(safeTop, 64))
    }
}

enum IslandGeometry {
    static func display(_ choice: IslandDisplayChoice, screens: [IslandDisplay], main: UInt32?, pointer: CGPoint) -> IslandDisplay? {
        let primary = screens.first { $0.id == main } ?? screens.first
        switch choice {
        case .automatic: return screens.first { $0.builtIn && $0.camera != nil } ?? screens.first { $0.camera != nil } ?? primary
        case .builtIn: return screens.first { $0.builtIn } ?? primary
        case .main: return primary
        case .pointer, .all: return screens.first { $0.frame.contains(pointer) } ?? primary
        }
    }
    static func closed(_ screen: IslandDisplay, settings: IslandSettings) -> CGSize {
        if let camera = screen.camera {
            return CGSize(width: max(1, camera.width + settings.notchWidth + (settings.outline ? 4 : 0)),
                          height: max(1, (settings.noGap ? max(camera.height, screen.menuHeight) : camera.height) + settings.notchHeight + (settings.outline ? 2 : 0)))
        }
        if settings.simulatedNotch { return CGSize(width: 180 * screen.menuHeight / 32, height: screen.menuHeight) }
        let margin = max(0, min(2, floor((screen.menuHeight - 20) / 2)))
        let height = max(16, screen.menuHeight - margin * 2 + settings.capsuleHeight)
        return CGSize(width: max(60, height * 5 + settings.capsuleWidth), height: height)
    }
    static func frame(_ screen: IslandDisplay, settings: IslandSettings, state: IslandPhase, hasRoom: Bool = false) -> CGRect {
        let base = closed(screen, settings: settings)
        let capsule = screen.camera == nil && !settings.simulatedNotch
        var size = base
        switch state {
        case .closed: break
        case .compact: size.width += hasRoom ? 88 : 0
        case .notice: size = CGSize(width: min(screen.frame.width - 24, max(base.width + 110, 340)), height: base.height + (capsule ? 0 : 32))
        case .peek, .drop: size = CGSize(width: max(base.width + 110, 340), height: (capsule ? 16 : base.height + 10) + (state == .drop ? 66 : 52))
        case .open:
            size.width = settings.size == .custom ? settings.customWidth : settings.size == .compact ? 480 : 560
            size.width = min(max(base.width + 36, size.width), max(base.width, screen.frame.width - 168))
            size.height = settings.size == .custom ? settings.customHeight : settings.size == .compact ? 286 : 370
            size.height = min(size.height, screen.frame.height - 48)
        }
        size.width = min(size.width, screen.frame.width - 24)
        let drop = capsule ? max(0, (screen.menuHeight - base.height) / 2) + settings.capsuleDrop : 0
        let scale = max(1, screen.scale)
        return CGRect(x: ((screen.frame.midX - size.width / 2) * scale).rounded() / scale,
                      y: ((screen.frame.maxY - drop - size.height) * scale).rounded() / scale,
                      width: size.width, height: size.height)
    }
}

enum IslandPhase: Equatable { case closed, compact, notice, peek, open, drop }
enum IslandNoticeKind: String {
    case level, timer, battery, accessory, agents, clipboard, download, track
    var priority: Int {
        switch self {
        case .level: return 5
        case .timer: return 4
        case .battery, .accessory, .agents: return 3
        case .clipboard, .download, .track: return 1
        }
    }
    var duration: Double {
        switch self {
        case .level: return 1.6
        case .timer, .download: return 6
        case .battery, .accessory: return 4
        case .agents: return 5
        case .clipboard: return 2.5
        case .track: return 3
        }
    }
}
struct IslandNotice: Equatable {
    var kind: IslandNoticeKind
    var title: String
    var section: IslandSection?
    var expires: Double
    var held = false
}
struct IslandState: Equatable {
    var phase = IslandPhase.closed
    var notice: IslandNotice?
    var activities: [IslandSection] = []
    var selectedActivity: IslandSection?
    var pinned = false
    var hoverOpened = false
    var suppressHover = false
    var suspended = false
    var protected = false
    var currentActivity: IslandSection? {
        if let selectedActivity, activities.contains(selectedActivity) { return selectedActivity }
        return [.timer, .downloads, .agents, .calendar, .music, .home].first { activities.contains($0) }
    }
    mutating func refresh(now: Double) {
        if let notice, !notice.held, notice.expires <= now { self.notice = nil }
        if activities.isEmpty { selectedActivity = nil }
        if phase == .closed || phase == .compact || phase == .notice {
            phase = notice != nil ? .notice : currentActivity != nil ? .compact : .closed
        }
    }
    @discardableResult mutating func show(_ kind: IslandNoticeKind, title: String, section: IslandSection?, now: Double) -> Bool {
        guard !suspended else { return false }
        if let notice, notice.kind != kind, notice.expires > now || notice.held {
            guard kind.priority >= notice.kind.priority else { return false }
        }
        notice = IslandNotice(kind: kind, title: title, section: section, expires: now + kind.duration)
        refresh(now: now)
        return true
    }
    mutating func open(hover: Bool) {
        guard !suspended, !hover || !suppressHover else { return }
        phase = .open
        hoverOpened = hover
        notice = nil
    }
    mutating func close(explicit: Bool, now: Double) {
        guard !protected, explicit || !pinned else { return }
        pinned = false
        phase = .closed
        notice = nil
        hoverOpened = false
        suppressHover = explicit
        refresh(now: now)
    }
    mutating func leave(now: Double) {
        suppressHover = false
        if phase == .peek || hoverOpened { close(explicit: false, now: now) }
    }
}

struct IslandTimer: Equatable {
    enum Mode: String, CaseIterable { case countdown, pomodoro, stopwatch }
    enum Phase: String { case focus, shortBreak, longBreak }
    struct Cycle: Equatable {
        var focus = 25
        var shortBreak = 5
        var longBreak = 15
        var every = 4
        var total = 4
    }
    var mode = Mode.countdown
    var phase = Phase.focus
    var cycle = Cycle()
    var session = 1
    var started: Double?
    var elapsed = 0.0
    var duration = 900.0
    var finished = false
    var begun = false
    var active: Bool { begun }
    func value(at now: Double) -> Double {
        let spent = max(0, elapsed + (started.map { max(0, now - $0) } ?? 0))
        return mode == .stopwatch ? min(359999, spent) : max(0, duration - spent)
    }
    mutating func start(now: Double, minutes: Int, mode: Mode, cycle: Cycle = Cycle()) {
        self = IslandTimer()
        self.mode = mode
        begun = true
        self.cycle = cycle
        duration = Double(min(180, max(1, mode == .pomodoro ? cycle.focus : minutes))) * 60
        started = now
    }
    mutating func pause(now: Double) {
        if let started { elapsed += max(0, now - started) }
        started = nil
    }
    mutating func resume(now: Double) { if !finished && started == nil { started = now } }
    @discardableResult mutating func tick(now: Double, suspended: Bool) -> Bool {
        guard !suspended, started != nil, !finished, mode != .stopwatch, value(at: now) <= 0 else { return false }
        elapsed = duration
        started = nil
        finished = true
        return true
    }
    mutating func next(now: Double) {
        guard mode == .pomodoro, finished else { return }
        if phase == .focus {
            if session >= max(1, cycle.total) { return }
            phase = session % max(1, cycle.every) == 0 ? .longBreak : .shortBreak
        } else { phase = .focus; session += 1 }
        let minutes = phase == .focus ? cycle.focus : phase == .shortBreak ? cycle.shortBreak : cycle.longBreak
        duration = Double(min(phase == .focus ? 180 : 60, max(1, minutes))) * 60
        elapsed = 0
        finished = false
        started = now
    }
    static func clock(_ value: Double, countdown: Bool) -> String {
        let safe = value.isFinite ? max(0, min(359999, value)) : 0
        let seconds = Int(countdown ? ceil(safe) : floor(safe))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct IslandEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var calendar: String
    var cancelled = false
    var declined = false
}
enum IslandCalendarLogic {
    static func groups(_ events: [IslandEvent], from: Date, days: Int, calendar: Calendar) -> [(Date, [IslandEvent])] {
        var seen = Set<String>()
        let valid = events.filter { !$0.cancelled && !$0.declined && $0.end > $0.start && seen.insert("\($0.id)|\($0.start.timeIntervalSince1970)").inserted }
        let start = calendar.startOfDay(for: from)
        return (0..<max(0, min(42, days))).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start), let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let rows = valid.filter { $0.start < end && $0.end > day }.sorted {
                if $0.allDay != $1.allDay { return $0.allDay }
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
            return (day, rows)
        }
    }
    static func countdown(_ events: [IslandEvent], now: Date, lead: Double = 3600) -> IslandEvent? {
        events.filter { !$0.allDay && !$0.cancelled && !$0.declined && $0.end > $0.start && $0.start > now && $0.start.timeIntervalSince(now) <= lead }
            .min { $0.start < $1.start }
    }
}

enum IslandDownloadLogic {
    static func finalName(_ name: String) -> String? {
        for suffix in [".crdownload", ".download", ".part"] where name.lowercased().hasSuffix(suffix) {
            let result = String(name.dropLast(suffix.count))
            return result.isEmpty ? nil : result
        }
        return nil
    }
    static func fraction(completed: Int64, total: Int64) -> Double? {
        guard total > 0, completed >= 0 else { return nil }
        return min(1, Double(completed) / Double(total))
    }
    static func completed(originalInode: UInt64, finalInode: UInt64?, publisherFinished: Bool) -> Bool {
        guard let finalInode else { return false }
        return publisherFinished || (originalInode > 0 && originalInode == finalInode)
    }
    static func live(modified: Date, now: Date, published: Bool) -> Bool { published || now.timeIntervalSince(modified) <= 120 }
}

struct IslandBatteryEdges {
    var previous: Int?
    var plugged: Bool?
    var lowArmed = true
    mutating func update(percent: Int, connected: Bool) -> String? {
        defer { previous = percent; plugged = connected }
        guard let previous, let plugged else { lowArmed = percent > 20; return nil }
        if percent > 20 { lowArmed = true }
        if connected != plugged { return connected ? "Power connected" : "Running on battery" }
        if percent == 100 && previous < 100 { return "Battery full" }
        if !connected && percent <= 20 && lowArmed { lowArmed = false; return "Battery low · \(percent)%" }
        return nil
    }
}

struct IslandMediaSample: Equatable {
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    var sampled: Date
    var rate: Double
    var playing: Bool
    func position(at date: Date) -> Double {
        guard duration.isFinite, duration > 0, duration <= 604800, elapsed.isFinite else { return 0 }
        let speed = rate.isFinite ? min(16, max(0, rate)) : 0
        return min(duration, max(0, elapsed + (playing ? max(0, date.timeIntervalSince(sampled)) * speed : 0)))
    }
}

struct IslandGesture {
    enum Action: Equatable { case open, close, next, previous }
    private var x = 0.0
    private var y = 0.0
    private var last = -Double.infinity
    private var fired = false
    mutating func consume(x dx: Double, y dy: Double, now: Double, precise: Bool, inverted: Bool, modified: Bool, open: Bool, music: Bool) -> Action? {
        guard !modified else { self = IslandGesture(); return nil }
        if now - last > 0.35 { self = IslandGesture() }
        last = now
        guard !fired else { return nil }
        let factor = precise ? 1.0 : 24.0
        x += dx * factor * (inverted ? -1 : 1)
        y += dy * factor * (inverted ? -1 : 1)
        guard max(abs(x), abs(y)) >= 4 else { return nil }
        var action: Action?
        if abs(y) >= abs(x) * 1.5, abs(y) >= 16 {
            if y < 0 && !open { action = .open }
            if y > 0 && open { action = .close }
        } else if music && abs(x) >= abs(y) * 1.5 && abs(x) >= 40 {
            action = x < 0 ? .next : .previous
        }
        if action != nil { fired = true }
        return action
    }
}
