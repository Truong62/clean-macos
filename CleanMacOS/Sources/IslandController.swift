import AppKit
import Combine
import Carbon
import KeyboardShortcuts
import SwiftUI
import UserNotifications

final class IslandPanel: NSPanel {
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .unknown }
}

@MainActor
final class IslandController: NSObject, ObservableObject {
    static let settingsKey = "island.settings"
    @Published var settings: IslandSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            apply(previous: oldValue)
        }
    }
    @Published var state = IslandState()
    @Published var section: IslandSection?
    @Published var exploring = false
    @Published var timer = IslandTimer()
    @Published var now = 0.0
    @Published var cameraStarted = false
    @Published private(set) var batteryPercent: Int?
    @Published private(set) var batteryPlugged = true
    @Published private(set) var capturePreview: NSImage?
    private var previewTask: Task<Void, Never>?
    @Published private(set) var display: IslandDisplay?
    @Published private(set) var fullScreen = false
    @Published private(set) var overview = false
    let files: IslandFileTools
    let context: CommandContext
    let music: MusicPlayer
    let mixer: MixerController
    let monitor: SystemMonitor
    let agents: AIUsageMonitor
    let calendar = IslandCalendarService()
    let downloads = IslandDownloads()
    let media = IslandMediaRemote()
    let bars = IslandBarsController()
    let watch = IslandWatchController()
    let lyrics = IslandLyricsController()
    @Published var musicPanel: IslandMusicPanel? { didSet { updateLyrics(); layout() } }
    @Published var musicNudge = 0.0
    private var lastTrack: IslandSong?
    private var agentNotices = IslandAgentNotices()
    private var accessoryQueue = IslandAccessoryQueue()
    private var accessoryBattery = IslandAccessoryBattery()
    @Published private(set) var menuRoom = IslandMenuRoom.unknown
    private let menuReader = IslandMenuReader()
    private let power = IslandPowerMonitor()
    private let bluetooth = IslandBluetoothMonitor()
    private let privateSpace = IslandSpace()
    private let lockScene = IslandLockScreen()
    private var unlockUntil = 0.0
    private var gesture = IslandGesture()
    private var panel: IslandPanel?
    private var copies: [IslandPanel] = []
    private var heartbeat: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var monitors: [Any] = []
    private var subscriptions = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var displayWork: DispatchWorkItem?
    private var suspension = Set<String>()
    private var normalReadings = 0
    private var pointerDisplay: UInt32?
    private var pointerSince = 0.0
    private var tickCount = 0
    private var topPressed = false
    private var lastDragCount = -1
    private var hadBuiltIn = false
    private var lastKeyboardLight: Float?
    private var lastVolume: Double?
    private var lastBrightness: [CGDirectDisplayID: Double] = [:]
    private var alarmStarted: Double?
    private var lastAlarm = 0.0
    private var previousApp: NSRunningApplication?
    private var menuOpen = false

    init(context: CommandContext, music: MusicPlayer, agents: AIUsageMonitor, mixer: MixerController, monitor: SystemMonitor) {
        self.context = context
        files = IslandFileTools(shelf: context.shelf)
        self.music = music
        self.agents = agents
        self.mixer = mixer
        self.monitor = monitor
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(IslandSettings.self, from: $0) } ?? IslandSettings()
        super.init()
        KeyboardShortcuts.onKeyUp(for: .island) { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        watch.onFinish = { [weak self] outcome in
            guard let self else { return }
            if self.settings.watchSound { NSSound(named: "Glass")?.play() }
            self.notice(.watch, outcome, section: .watch)
            if self.state.suspended || self.overview || self.fullScreen && self.settings.hideInFullScreen || self.panel?.isVisible != true || self.state.notice?.kind != .watch {
                let content = UNMutableNotificationContent()
                content.title = "Screen Watch"
                content.body = outcome
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
        context.camera.openInIsland = { [weak self] in
            guard let self, self.settings.isEnabled, self.settings.sections.contains(.camera), !self.state.suspended else { return false }
            self.open()
            self.select(.camera)
            self.startCamera()
            return true
        }
        KeyboardShortcuts.onKeyUp(for: .islandWatch) { [weak self] in MainActor.assumeIsolated { self?.pickWatchArea() } }
        context.screenTools.screenshot?.onIslandCapture = { [weak self] image in
            guard let self, self.settings.isEnabled, self.settings.sections.contains(.captures), !self.state.suspended else { return }
            self.capturePreview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            self.notice(.capture, "Screenshot captured", section: .captures)
            self.previewTask?.cancel()
            self.previewTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                self?.capturePreview = nil
            }
        }
        context.shelf.openInIsland = { [weak self] in
            self?.open()
            self?.select(.files)
        }
        downloads.onFinish = { [weak self] name in self?.notice(.download, name, section: .downloads) }
        power.onNotice = { [weak self] message in
            guard let self, self.settings.batteryNotices else { return }
            self.notice(.battery, message)
        }
        power.onReading = { [weak self] percent, plugged in self?.batteryPercent = percent; self?.batteryPlugged = plugged }
        bluetooth.onNotice = { [weak self] message in
            guard let self else { return }
            self.accessoryQueue.enqueue(id: message, title: message, now: self.clock)
        }
        context.sound.$mic.dropFirst().sink { [weak self] value in
            guard let self, self.settings.levelNotices else { return }
            self.notice(.level, value.isMuted ? "Microphone muted" : "Microphone unmuted", section: .home)
        }.store(in: &subscriptions)
        context.sound.$outputVolume.dropFirst().sink { [weak self] value in
            guard let self, let value else { return }
            defer { self.lastVolume = value }
            if self.settings.levelNotices, self.lastVolume != nil, self.lastVolume != value {
                self.notice(.level, "Volume · \(Int(value * 100))%", section: .home)
            }
        }.store(in: &subscriptions)
        context.brightness.$displays.dropFirst().sink { [weak self] displays in
            guard let self else { return }
            for display in displays {
                if self.settings.levelNotices, let old = self.lastBrightness[display.id], old != display.level {
                    self.notice(.level, "Brightness · \(Int(display.level * 100))%", section: .home)
                }
                self.lastBrightness[display.id] = display.level
            }
        }.store(in: &subscriptions)
        apply(previous: nil)
    }

    var enabledTurns: [IslandAgentTurn] {
        agents.islandTurns.filter { $0.agent == .claude ? settings.claudeActivity : settings.codexActivity }
    }
    func agentUsage(_ turn: IslandAgentTurn) -> UsageSlice {
        var value = UsageSlice(name: turn.agent.title)
        for row in agents.rows where row.agent == turn.agent && row.session == turn.session && row.date >= turn.start && row.date <= (turn.end ?? Date()) {
            value.add(row, cost: AIPricing.price(for: row, in: agents.prices).map { AIPricing.cost(row, at: $0) })
        }
        return value
    }
    func agentCost(_ usage: UsageSlice) -> String {
        guard usage.requests > 0, usage.isPriced else { return "Cost unavailable" }
        return String(format: "$%.2f est.", usage.cost)
    }
    var song: IslandSong? {
        if let track = music.current { return IslandSong(title: track.title, artist: track.artist, album: track.album, duration: track.duration) }
        return media.sample.map { IslandSong(title: $0.title, artist: $0.artist, album: $0.album, duration: $0.duration) }
    }
    var musicSample: IslandMediaSample? {
        if let track = music.current {
            return IslandMediaSample(title: track.title, artist: track.artist, duration: track.duration, elapsed: music.currentTime, sampled: Date(), rate: 1, playing: music.isPlaying, album: track.album)
        }
        return media.sample
    }
    private func updateLyrics() {
        lyrics.update(song: song, sample: musicSample, visible: settings.isEnabled && settings.lyrics && isOpen && section == .music && musicPanel == .lyrics && !state.suspended, online: settings.onlineLyrics)
    }
    func skipMusic(next: Bool) {
        if music.current != nil { if next { music.next() } else { music.previous() } }
        else { media.command(next ? 4 : 5) }
        musicNudge = next ? -8 : 8
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.musicNudge = 0 }
    }
    func seekMusic(_ position: Double) {
        if music.current != nil { music.seek(to: position) } else { media.seek(position) }
    }
    func toggleMusic() {
        if music.current != nil { music.togglePlayPause() } else { media.command(2) }
    }
    var isOpen: Bool { state.phase == .open }
    var clock: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
    var visibleSections: [IslandSection] { settings.sections }
    var timerText: String { IslandTimer.clock(timer.value(at: now), countdown: timer.mode != .stopwatch) }
    var compactReading: String {
        switch state.currentActivity {
        case .timer: return timerText
        case .watch: return watch.headline
        case .agents: return activityTitle.components(separatedBy: " · ").last ?? ""
        case .home: return activityTitle.components(separatedBy: " · ").last ?? ""
        case .downloads: return "Downloading"
        default: return ""
        }
    }
    var compactWing: Double {
        let width = Double(compactReading.count) * 6 + 12
        return state.currentActivity == .watch ? min(150, max(56, width)) : min(80, max(44, width))
    }
    var activityTitle: String {
        switch state.currentActivity {
        case .watch: return watch.headline
        case .timer: return timer.finished ? "Timer done" : timerText
        case .music: return music.current?.title ?? media.sample?.title ?? "Now Playing"
        case .downloads: return downloads.items.first(where: { !$0.finished })?.name ?? "Downloads"
        case .calendar: return IslandCalendarLogic.countdown(calendar.events, now: Date())?.title ?? "Calendar"
        case .agents:
            guard let turn = enabledTurns.first(where: { $0.working(at: Date()) }) else { return "AI agents" }
            let usage = agentUsage(turn)
            let reading: String
            switch settings.agentReading {
            case .elapsed: reading = IslandTimer.clock(turn.duration(at: Date()), countdown: false)
            case .tokens: reading = "\(usage.tokens.total) tokens"
            case .cost: reading = agentCost(usage)
            case .limit: reading = agents.limits?.windows.map { $0.percent(at: Date()) }.max().map { "\(Int($0))%" } ?? "—"
            }
            return "\(turn.agent.title) · \(reading)"
        case .home: return "Keep Awake · " + (context.keepAwake.session?.remaining(now: Date()).map { "\(Int(ceil($0 / 60))) min" } ?? "∞")
        default: return "Island"
        }
    }

    private func apply(previous: IslandSettings?) {
        monitor.islandBatteryColors = settings.batteryColors
        if previous?.liveBars == false && settings.liveBars { bars.mayRequestAccess = true }
        if !settings.liveBars { bars.stop(); bars.mayRequestAccess = false }
        context.shelf.isHostedInIsland = settings.isEnabled && settings.sections.contains(.files)
        if settings.isEnabled && settings.shortcut { KeyboardShortcuts.enable([.island]) } else { KeyboardShortcuts.disable([.island]) }
        if settings.isEnabled && settings.watchShortcut && settings.sections.contains(.watch) { KeyboardShortcuts.enable([.islandWatch]) } else { KeyboardShortcuts.disable([.islandWatch]) }
        agents.tracksIslandTurns = settings.isEnabled && settings.sections.contains(.agents) && (settings.claudeActivity || settings.codexActivity)
        guard settings.isEnabled else { stop(); return }
        if heartbeat == nil { start() }
        if previous?.sections != settings.sections || previous?.isEnabled != settings.isEnabled {
            let active = suspension.isEmpty
            calendar.setEnabled(active && settings.sections.contains(.calendar))
            downloads.setEnabled(active && settings.sections.contains(.downloads))
            if !settings.sections.contains(.watch) { watch.stop() }
            if !settings.sections.contains(.music) { media.stop() }
            if !settings.sections.contains(.timer) { timer = IslandTimer(); alarmStarted = nil }
            if let section, !settings.sections.contains(section) { select(nil) }
        }
        if (settings.batteryNotices || settings.batteryColors.enabled) && suspension.isEmpty { power.start() } else { power.stop() }
        if settings.bluetoothNotices && suspension.isEmpty { bluetooth.start() } else { bluetooth.stop(); accessoryQueue = IslandAccessoryQueue(); accessoryBattery = IslandAccessoryBattery() }
        if musicPanel == .lyrics && !settings.lyrics || musicPanel == .queue && !settings.queue { musicPanel = nil }
        updateLyrics()
        rebuild()
    }

    private func start() {
        now = clock
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) { [weak self] in self?.scheduleRebuild() }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if session["CGSSessionScreenIsLocked"] as? Bool == true { suspension.insert("com.apple.screenIsLocked") }
            if session[kCGSessionOnConsoleKey as String] as? Bool == false { suspension.insert("session") }
            state.suspended = !suspension.isEmpty
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, center: workspace) { [weak self] in self?.suspend("sleep", true) }
        observe(NSWorkspace.didWakeNotification, center: workspace) { [weak self] in self?.suspend("sleep", false) }
        observe(NSWorkspace.screensDidSleepNotification, center: workspace) { [weak self] in self?.suspend("display", true) }
        observe(NSWorkspace.screensDidWakeNotification, center: workspace) { [weak self] in self?.suspend("display", false) }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { [weak self] in self?.suspend("session", true) }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { [weak self] in self?.suspend("session", false) }
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { [weak self] in self?.inspectWindows(); self?.rebuild() }
        observe(NSWorkspace.didActivateApplicationNotification, center: workspace) { [weak self] in
            guard let self else { return }
            self.close(explicit: false)
            self.calendar.refresh()
        }
        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), center: distributed) { [weak self] in
            guard let self, self.settings.levelNotices,
                  let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return }
            self.notice(.level, Unmanaged<CFString>.fromOpaque(name).takeUnretainedValue() as String)
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observe(Notification.Name(name), center: distributed) { [weak self] in self?.suspend(name, true) }
        }
        observe(Notification.Name("com.apple.screenIsUnlocked"), center: distributed) { [weak self] in self?.suspend("com.apple.screenIsLocked", false) }
        observe(Notification.Name("com.apple.screensaver.didstop"), center: distributed) { [weak self] in self?.suspend("com.apple.screensaver.didstart", false) }
        observe(Notification.Name("MacKit.Island.Watch"), center: .default) { [weak self] in self?.pickWatchArea() }
        observe(Notification.Name("MacKit.Island.Toggle"), center: .default) { [weak self] in self?.toggle() }
        observe(NSMenu.didBeginTrackingNotification, center: .default) { [weak self] in self?.menuOpen = true }
        observe(NSMenu.didEndTrackingNotification, center: .default) { [weak self] in self?.menuOpen = false }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        installMonitors()
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter, action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }

    private func stop() {
        lockScene.hide(immediate: true)
        previewTask?.cancel()
        capturePreview = nil
        menuReader.cancel()
        heartbeat?.invalidate()
        heartbeat = nil
        hoverWork?.cancel()
        displayWork?.cancel()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.orderOut(nil)
        privateSpace.detach()
        panel = nil
        copies.forEach { $0.orderOut(nil) }
        copies = []
        stopCamera()
        calendar.setEnabled(false)
        downloads.setEnabled(false)
        media.stop()
        lyrics.close()
        watch.stop()
        bars.stop()
        musicPanel = nil
        power.stop()
        bluetooth.stop()
        alarmStarted = nil
        timer = IslandTimer()
        state = IslandState()
        accessoryQueue = IslandAccessoryQueue()
        suspension = []
    }

    private func suspend(_ reason: String, _ value: Bool) {
        if reason == "com.apple.screenIsLocked" && !value { unlockUntil = clock + 0.55 }
        if reason == "com.apple.screenIsLocked" && settings.lockSounds && settings.lockScreen { NSSound(named: "Tink")?.play() }
        if value { suspension.insert(reason) } else { suspension.remove(reason) }
        state.suspended = !suspension.isEmpty
        if state.suspended {
            state.notice = nil
            accessoryQueue = IslandAccessoryQueue()
            accessoryBattery = IslandAccessoryBattery()
            state.phase = .closed
            panel?.orderOut(nil)
            privateSpace.detach()
            copies.forEach { $0.orderOut(nil) }
            stopCamera()
            calendar.setEnabled(false)
            downloads.setEnabled(false)
            media.stop()
            lyrics.close()
            watch.pause()
            bars.stop()
            musicPanel = nil
            power.stop()
            bluetooth.stop()
        } else { lockScene.hide(); apply(previous: nil); tick() }
        updateLockScene()
    }

    private static func screens() -> [IslandDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return IslandDisplay(id: id, frame: screen.frame, visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor,
                          safeTop: screen.safeAreaInsets.top, leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea,
                          builtIn: CGDisplayIsBuiltin(id) != 0)
        }
    }

    private func scheduleRebuild() {
        displayWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.rebuild() } }
        displayWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func rebuild() {
        guard settings.isEnabled, !state.suspended else { return }
        let screens = Self.screens()
        if screens.contains(where: \.builtIn) { hadBuiltIn = true }
        if settings.display == .builtIn, hadBuiltIn, !screens.contains(where: \.builtIn) {
            panel?.orderOut(nil)
            copies.forEach { $0.orderOut(nil) }
            stopCamera()
            display = nil
            return
        }
        if let current = display, isOpen || state.notice != nil || timer.active {
            guard let updated = screens.first(where: { $0.id == current.id }) else {
                panel?.orderOut(nil)
                copies.forEach { $0.orderOut(nil) }
                stopCamera()
                display = nil
                return
            }
            display = updated
        } else {
            display = IslandGeometry.display(settings.display, screens: screens, main: NSScreen.screens.first?.displayID, pointer: NSEvent.mouseLocation)
        }
        guard display != nil else { panel?.orderOut(nil); return }
        if panel == nil {
            let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            configure(panel)
            let host = NSHostingController(rootView: IslandPanelView(controller: self))
            host.sizingOptions = []
            panel.contentViewController = host
            self.panel = panel
        }
        if let panel { privateSpace.attach(panel) }
        layout()
        copies.forEach { $0.orderOut(nil) }
        copies = []
        if settings.display == .all {
            for screen in screens where screen.id != display?.id {
                let copy = IslandPanel(contentRect: IslandGeometry.frame(screen, settings: settings, state: .closed), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                configure(copy)
                let host = NSHostingController(rootView: Button { [weak self] in
                    guard let self else { return }
                    self.panel?.orderOut(nil)
                    self.display = screen
                    self.open()
                } label: { Color.black.frame(maxWidth: .infinity, maxHeight: .infinity) }.buttonStyle(.plain).clipShape(Capsule()))
                host.sizingOptions = []
                copy.contentViewController = host
                copy.orderFrontRegardless()
                copies.append(copy)
            }
        }
    }

    private func configure(_ panel: IslandPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.sharingType = settings.includeInCaptures ? .readOnly : .none
        panel.isReleasedWhenClosed = false
    }

    func layout() {
        guard let panel, let display, settings.isEnabled, !state.suspended else { return }
        guard clock >= unlockUntil else { panel.orderOut(nil); return }
        panel.acceptsKeyboard = isOpen && !state.hoverOpened
        panel.sharingType = settings.includeInCaptures ? .readOnly : .none
        let resting = state.phase == .closed || state.phase == .compact
        let roomHidden = resting && display.camera == nil && (menuRoom.overlaps || (settings.simulatedNotch && !menuRoom.known))
        let hides = roomHidden || (fullScreen && settings.hideInFullScreen && display.camera == nil && !isOpen) ||
            (settings.opening == .hidden && state.phase == .closed)
        let point = NSEvent.mouseLocation
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        let shape = IslandSilhouette(capsule: display.camera == nil && !settings.simulatedNotch,
                                     neckWidth: display.camera?.width ?? 0, neckHeight: display.menuHeight)
        panel.ignoresMouseEvents = overview || hides || !shape.path(in: CGRect(origin: .zero, size: panel.frame.size)).contains(local)
        panel.alphaValue = overview || hides ? 0 : 1
        panel.level = fullScreen && display.camera == nil ? .floating : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        var frame = IslandGeometry.frame(display, settings: settings, state: state.phase, hasRoom: menuRoom.known && min(menuRoom.left, menuRoom.right) >= 44)
        if isOpen && section == .music && musicPanel != nil {
            let extra = min(216, max(0, display.frame.height - 48 - frame.height))
            frame.origin.y -= extra
            frame.size.height += extra
        }
        let closedWidth = IslandGeometry.closed(display, settings: settings).width
        if state.phase == .compact, menuRoom.known, min(menuRoom.left, menuRoom.right) >= compactWing {
            let width = min(display.frame.width - 24, closedWidth + compactWing * 2)
            frame.origin.x = display.frame.midX - width / 2
            frame.size.width = width
        }
        let growsIntoMenu = (frame.width - closedWidth) / 2 > min(menuRoom.left, menuRoom.right)
        if display.camera == nil && !resting && (menuRoom.overlaps || growsIntoMenu || !menuRoom.known) {
            frame.origin.y = display.frame.maxY - display.menuHeight - frame.height - 6
        }
        let moved = panel.frame.midX != frame.midX || panel.frame.maxY != frame.maxY
        if moved { panel.orderOut(nil) }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func toggle() {
        guard settings.isEnabled else { return }
        if isOpen { close(explicit: true) } else { open() }
    }

    func open(hover: Bool = false) {
        guard settings.isEnabled, !state.suspended, !overview else { return }
        if hover && fullScreen && settings.hideInFullScreen && !settings.fullScreenHover { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        if let notice = state.notice, let target = notice.section, visibleSections.contains(target) { section = target }
        else if let target = state.currentActivity, visibleSections.contains(target) { section = target }
        if section == nil { section = visibleSections.first }
        state.open(hover: hover)
        guard isOpen else { return }
        NotificationCenter.default.post(name: Notification.Name("MacKit.Island.Opened"), object: nil)
        layout()
        if !hover { panel?.makeKey() }
        haptic()
    }

    func close(explicit: Bool = true) {
        state.protected = AirPlayRoutes.pickerIsOpen || Date() < AirPlayRoutes.dismissalAllowedAfter || calendar.isRequestingAccess || context.camera.isRequestingAccess || menuOpen || NSApp.modalWindow != nil || panel?.attachedSheet != nil || context.scratchpad.pendingClose != nil
        state.close(explicit: explicit, now: clock)
        guard !isOpen else { return }
        stopCamera()
        musicPanel = nil
        lyrics.close()
        exploring = false
        layout()
    }

    func select(_ section: IslandSection?) {
        if self.section != section { stopCamera(); musicPanel = nil; lyrics.close() }
        if section == .system { monitor.popoverDidOpen() }
        if self.section == .system && section != .system { monitor.popoverDidClose() }
        self.section = section
        updateLyrics()
        layout()
        exploring = section == nil
        haptic()
    }

    func showSettings() {
        close()
        context.openPage(.island)
    }

    func hover(_ inside: Bool) {
        hoverWork?.cancel()
        if inside {
            if state.notice != nil { state.notice?.held = true }
            guard !state.suppressHover else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isOpen else { return }
                    self.hoverWork = nil
                    if self.fullScreen && self.settings.hideInFullScreen && !self.settings.fullScreenHover { return }
                    if self.state.activities.count > 1 || self.settings.opening == .preview {
                        self.state.phase = .peek
                        self.layout()
                    } else if self.settings.opening == .hover || self.settings.opening == .hidden { self.open(hover: true) }
                }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + settings.activationDelay, execute: work)
        } else {
            if state.notice != nil { state.notice?.held = false; state.notice?.expires = clock + 1 }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hoverWork = nil
                    self.state.protected = self.menuOpen || self.calendar.isRequestingAccess || self.context.camera.isRequestingAccess || NSApp.modalWindow != nil
                    self.state.leave(now: self.clock)
                    if !self.isOpen { self.stopCamera() }
                    self.layout()
                }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (state.phase == .peek ? 0.12 : settings.closingDelay), execute: work)
        }
    }

    func notice(_ kind: IslandNoticeKind, _ title: String, section: IslandSection? = nil) {
        guard settings.isEnabled, !state.suspended, !overview, !(fullScreen && settings.hideInFullScreen),
              kind == .level || section == nil || visibleSections.contains(section!) else { return }
        state.show(kind, title: title, section: section, now: clock)
        layout()
    }

    func startTimer(mode: IslandTimer.Mode, cycle: IslandTimer.Cycle) {
        timer.start(now: clock, minutes: settings.timerMinutes, mode: mode, cycle: cycle)
        alarmStarted = nil
        tick()
    }

    func acknowledgeTimer() { alarmStarted = nil; state.notice = nil; timer = IslandTimer(); tick() }

    func pickWatchArea() {
        guard settings.isEnabled, !state.suspended, settings.sections.contains(.watch), let capture = context.screenTools.screenshot else { return }
        close()
        capture.pickRegion { [weak self] rect, shot, window in
            guard let self, self.settings.isEnabled, !self.state.suspended else { return }
            let mainTop = NSScreen.screens.first?.frame.maxY ?? 0
            let global = CGRect(x: shot.frame.minX + rect.minX, y: mainTop - shot.frame.maxY + rect.minY, width: rect.width, height: rect.height)
            let local = window.map { global.offsetBy(dx: -$0.frame.minX, dy: -$0.frame.minY).intersection(CGRect(origin: .zero, size: $0.frame.size)) }
            let app = window.flatMap { NSRunningApplication(processIdentifier: $0.owner)?.localizedName } ?? "Display"
            self.watch.start(IslandWatchTarget(display: shot.id, rect: rect, window: window?.id, windowRect: local, app: app))
            self.open()
            self.select(.watch)
        }
    }

    func startCamera() {
        cameraStarted = true
        context.camera.startEmbedded()
    }

    private func stopCamera() {
        if cameraStarted { context.camera.stopEmbedded() }
        cameraStarted = false
    }

    func paste(_ item: ClipboardItem) {
        close()
        guard context.clipboard.copy(item), let app = previousApp,
              !ClipboardPanelController.copyOnlyApps.contains(app.bundleIdentifier ?? "") else { return }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipboardPanelController.pasteDelay) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            PasteService.whenModifiersReleased(timeout: 1.5) { PasteService.pasteToFrontmostApp() }
        }
    }

    private func haptic() {
        if settings.haptics && panel?.isVisible == true { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    private func updateLockScene() {
        let visible = IslandLockPolicy.visible(enabled: settings.isEnabled && settings.lockScreen, reasons: suspension, supported: IslandSpace.supportsAbsoluteLevel)
        if visible {
            now = clock
            media.refresh()
        }
        lockScene.update(self, visible: visible)
    }

    private func tick() {
        guard settings.isEnabled else { return }
        if state.suspended { updateLockScene(); return }
        now = clock
        tickCount += 1
        if settings.levelNotices && tickCount % 4 == 0, let value = context.brightness.keyboard.brightness {
            if let previous = lastKeyboardLight, abs(previous - value) > 0.001 { notice(.level, "Keyboard light · \(Int(value * 100))%") }
            lastKeyboardLight = value
        }
        if settings.bluetoothNotices && tickCount % 20 == 0 {
            monitor.refreshAccessoryBatteries()
            for reading in monitor.accessoryBatteries {
                if reading.percent >= 25 { accessoryQueue.recover(reading.id) }
                if accessoryBattery.update(id: reading.id, percent: reading.percent, sampled: reading.sampled, now: Date(), hid: true) {
                    accessoryQueue.enqueue(id: reading.id, title: "Low battery · \(reading.name) · \(reading.percent)%", now: now, warning: true)
                }
            }
        }
        if timer.tick(now: now, suspended: display == nil) {
            notice(.timer, "Timer finished", section: .timer)
            alarmStarted = now
        }
        if let alarmStarted, now - alarmStarted < 300, now - lastAlarm >= 2, settings.timerSound, display != nil {
            NSSound(named: "Glass")?.play()
            lastAlarm = now
        }
        if settings.sections.contains(.music), !(fullScreen && settings.hideInFullScreen) { media.refresh() }
        updateLyrics()
        watch.tick(pageOpen: isOpen && section == .watch)
        bars.update(enabled: settings.liveBars && settings.sections.contains(.music) && !(fullScreen && settings.hideInFullScreen), playing: musicSample?.playing == true, song: song, pid: music.current != nil ? getpid() : media.playerPID)
        if settings.sections.contains(.agents), agents.settings.isEnabled {
            if settings.agentFinishedNotices {
                for turn in agentNotices.finished(enabledTurns, now: Date(), minimum: Double(settings.agentMinimumSeconds)) {
                    let usage = agentUsage(turn)
                    notice(.agents, "\(turn.agent.title) finished · \(IslandTimer.clock(turn.duration(at: Date()), countdown: false)) · \(agentCost(usage))", section: .agents)
                }
            }
            if settings.agentLimitNotices {
                for message in agentNotices.limits(agents.limits, now: Date(), threshold: Double(settings.agentLimitThreshold)) { notice(.agents, message, section: .agents) }
            }
        }
        let currentTrack = song
        if settings.trackNotices, let currentTrack, let previous = lastTrack, previous != currentTrack {
            notice(.track, currentTrack.title, section: .music)
        }
        lastTrack = currentTrack
        var activities: [IslandSection] = []
        if timer.active && settings.sections.contains(.timer) { activities.append(.timer) }
        if watch.active && settings.sections.contains(.watch) { activities.append(.watch) }
        if settings.sections.contains(.agents), agents.settings.isEnabled, enabledTurns.contains(where: { $0.working(at: Date()) }) { activities.append(.agents) }
        if settings.sections.contains(.downloads), downloads.items.contains(where: { !$0.finished && IslandDownloadLogic.live(modified: $0.modified, now: Date(), published: false) }) { activities.append(.downloads) }
        if settings.sections.contains(.music), music.isPlaying || media.sample?.playing == true { activities.append(.music) }
        if settings.keepAwakeActivity && settings.sections.contains(.home), context.keepAwake.isActive { activities.append(.home) }
        if settings.calendarCountdown && settings.sections.contains(.calendar), IslandCalendarLogic.countdown(calendar.events, now: Date()) != nil { activities.append(.calendar) }
        if fullScreen && settings.hideInFullScreen { activities = [] }
        state.activities = activities
        state.refresh(now: now)
        if let entry = accessoryQueue.next(now: now, closed: !isOpen && state.notice == nil && (state.phase == .closed || state.phase == .compact)) {
            notice(.accessory, entry.title)
        }
        inspectWindows()
        if tickCount % 4 == 0, let display {
            let frame = IslandGeometry.frame(display, settings: settings, state: .closed)
            menuReader.read(display: display, camera: frame) { [weak self] room in self?.menuRoom = room; self?.layout() }
        }
        followPointer()
        layout()
    }

    private func followPointer() {
        guard !isOpen, state.notice == nil, !timer.active, settings.display == .pointer || settings.display == .all else { return }
        let target = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.displayID
        if target != pointerDisplay { pointerDisplay = target; pointerSince = now }
        if target != display?.id, now - pointerSince >= 0.2 { rebuild() }
    }

    private func inspectWindows() {
        guard let display else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let mainTop = NSScreen.screens.first?.frame.maxY ?? display.frame.maxY
        let target = CGRect(x: display.frame.minX, y: mainTop - display.frame.maxY, width: display.frame.width, height: display.frame.height)
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var isFull = privateSpace.isFullScreen(displayID: display.id) ?? false
        var isOverview = false
        for window in windows {
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let covers = frame.intersection(target).width >= target.width - 2 && frame.intersection(target).height >= target.height - 2
            let owner = window[kCGWindowOwnerName as String] as? String
            if owner == "Dock", covers, (window[kCGWindowLayer as String] as? Int ?? 0) > 0 { isOverview = true }
            if (window[kCGWindowOwnerPID as String] as? Int32) == pid, (window[kCGWindowLayer as String] as? Int) == 0, covers { isFull = true }
        }
        if isOverview { normalReadings = 0; overview = true }
        else { normalReadings += 1; if normalReadings >= 3 { overview = false } }
        if isFull != fullScreen {
            fullScreen = isFull
            if isFull && settings.hideInFullScreen {
                state.pinned = false
                state.protected = false
                close()
                state.notice = nil
                media.stop()
            }
        }
        if overview { panel?.ignoresMouseEvents = true; copies.forEach { $0.orderOut(nil) } }
    }

    private func installMonitors() {
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .mouseMoved]
        if let token = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouse(event) }
        }) { monitors.append(token) }
        if let token = NSEvent.addLocalMonitorForEvents(matching: mouseMask.union([.keyDown, .scrollWheel]), handler: { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown { return self.key(event) }
                if event.type == .scrollWheel, self.settings.gestures, let panel = self.panel, panel.frame.contains(NSEvent.mouseLocation) {
                    let inHeader = NSEvent.mouseLocation.y > panel.frame.maxY - 80
                    if !self.isOpen || inHeader || (self.section == .music && self.musicPanel == nil) {
                        let action = self.gesture.consume(x: event.scrollingDeltaX, y: event.scrollingDeltaY, now: self.clock,
                                                          precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice,
                                                          modified: !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                                                          open: self.isOpen, music: self.section == .music, momentum: !event.momentumPhase.isEmpty, began: event.phase == .began,
                                                          blocked: self.menuOpen || self.section == .captures || self.state.phase == .drop || self.context.shelf.isDraggingContent)
                        switch action {
                        case .open: self.open()
                        case .close: self.close()
                        case .next: self.skipMusic(next: true)
                        case .previous: self.skipMusic(next: false)
                        case nil: break
                        }
                        if action != nil { return true }
                    }
                }
                self.mouse(event)
                return false
            }
            return handled ? nil : event
        }) { monitors.append(token) }
    }

    private func mouse(_ event: NSEvent) {
        guard settings.isEnabled, !state.suspended, !overview, let panel, let display else { return }
        let point = NSEvent.mouseLocation
        let top = point.y >= display.frame.maxY - 1 && point.x >= panel.frame.minX && point.x <= panel.frame.maxX
        if event.type == .leftMouseDown {
            topPressed = top
            if isOpen, let camera = display.camera, point.y > display.frame.maxY - camera.height,
               abs(point.x - display.frame.midX) <= camera.width / 2 { close(); return }
        }
        if event.type == .leftMouseUp {
            if topPressed && top { toggle() }
            topPressed = false
            if state.phase == .drop { state.phase = .closed; layout() }
        }
        if event.type == .leftMouseDragged {
            if !top { topPressed = false }
            let board = NSPasteboard(name: .drag)
            if settings.fileDropTarget && settings.sections.contains(.files), context.shelf.settings.isEnabled, board.changeCount != lastDragCount,
               board.availableType(from: Array(ShelfController.accepted)) != nil {
                lastDragCount = board.changeCount
                state.phase = .drop
                layout()
            }
        }
        if event.type == .mouseMoved {
            layout()
            if settings.opening == .hidden, panel.frame.contains(point), hoverWork == nil { hover(true) }
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type), !panel.frame.contains(point),
           !copies.contains(where: { $0.frame.contains(point) }), point.y < display.frame.maxY - display.menuHeight { close(explicit: false) }
    }

    private func key(_ event: NSEvent) -> Bool {
        guard isOpen, event.window === panel else { return false }
        if let input = panel?.firstResponder as? NSTextView, input.hasMarkedText() { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 {
            if musicPanel != nil { musicPanel = nil } else if exploring { exploring = false } else { close() }
            return true
        }
        if modifiers == .command && event.charactersIgnoringModifiers == "k" { exploring.toggle(); return true }
        if modifiers == .command && event.charactersIgnoringModifiers == "," { showSettings(); return true }
        if modifiers == [.command, .option], let target = visibleSections.first(where: { $0.letter == event.charactersIgnoringModifiers }) { select(target); return true }
        if event.keyCode == 48 && modifiers.contains(.control), !visibleSections.isEmpty {
            let current = section.flatMap { visibleSections.firstIndex(of: $0) } ?? 0
            select(visibleSections[(current + (modifiers.contains(.shift) ? visibleSections.count - 1 : 1)) % visibleSections.count])
            return true
        }
        return false
    }
}
