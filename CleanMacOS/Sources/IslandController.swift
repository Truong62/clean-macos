import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

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
    @Published private(set) var display: IslandDisplay?
    @Published private(set) var fullScreen = false
    @Published private(set) var overview = false
    let context: CommandContext
    let music: MusicPlayer
    let mixer: MixerController
    let monitor: SystemMonitor
    let agents: AIUsageMonitor
    let calendar = IslandCalendarService()
    let downloads = IslandDownloads()
    let media = IslandMediaRemote()
    @Published private(set) var menuRoom = IslandMenuRoom.unknown
    private let menuReader = IslandMenuReader()
    private let power = IslandPowerMonitor()
    private let bluetooth = IslandBluetoothMonitor()
    private let privateSpace = IslandSpace()
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
    private var lastVolume: Double?
    private var lastBrightness: [CGDirectDisplayID: Double] = [:]
    private var alarmStarted: Double?
    private var lastAlarm = 0.0
    private var previousApp: NSRunningApplication?
    private var menuOpen = false

    init(context: CommandContext, music: MusicPlayer, agents: AIUsageMonitor, mixer: MixerController, monitor: SystemMonitor) {
        self.context = context
        self.music = music
        self.agents = agents
        self.mixer = mixer
        self.monitor = monitor
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(IslandSettings.self, from: $0) } ?? IslandSettings()
        super.init()
        KeyboardShortcuts.onKeyUp(for: .island) { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        context.shelf.openInIsland = { [weak self] in
            self?.open()
            self?.select(.files)
        }
        downloads.onFinish = { [weak self] name in self?.notice(.download, name, section: .downloads) }
        power.onNotice = { [weak self] message in self?.notice(.battery, message) }
        bluetooth.onNotice = { [weak self] message in self?.notice(.accessory, message) }
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

    var isOpen: Bool { state.phase == .open }
    var clock: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
    var visibleSections: [IslandSection] { settings.sections }
    var timerText: String { IslandTimer.clock(timer.value(at: now), countdown: timer.mode != .stopwatch) }
    var activityTitle: String {
        switch state.currentActivity {
        case .timer: return timer.finished ? "Timer done" : timerText
        case .music: return music.current?.title ?? media.sample?.title ?? "Now Playing"
        case .downloads: return downloads.items.first(where: { !$0.finished })?.name ?? "Downloads"
        case .calendar: return IslandCalendarLogic.countdown(calendar.events, now: Date())?.title ?? "Calendar"
        case .agents: return "AI agents working"
        case .home: return "Keep Awake"
        default: return "Island"
        }
    }

    private func apply(previous: IslandSettings?) {
        context.shelf.isHostedInIsland = settings.isEnabled && settings.sections.contains(.files)
        if settings.isEnabled && settings.shortcut { KeyboardShortcuts.enable([.island]) } else { KeyboardShortcuts.disable([.island]) }
        guard settings.isEnabled else { stop(); return }
        if heartbeat == nil { start() }
        if previous?.sections != settings.sections || previous?.isEnabled != settings.isEnabled {
            let active = suspension.isEmpty
            calendar.setEnabled(active && settings.sections.contains(.calendar))
            downloads.setEnabled(active && settings.sections.contains(.downloads))
            if !settings.sections.contains(.music) { media.stop() }
            if !settings.sections.contains(.timer) { timer = IslandTimer(); alarmStarted = nil }
            if let section, !settings.sections.contains(section) { select(nil) }
        }
        if settings.batteryNotices && suspension.isEmpty { power.start() } else { power.stop() }
        if settings.bluetoothNotices && suspension.isEmpty { bluetooth.start() } else { bluetooth.stop() }
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
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observe(Notification.Name(name), center: distributed) { [weak self] in self?.suspend(name, true) }
        }
        observe(Notification.Name("com.apple.screenIsUnlocked"), center: distributed) { [weak self] in self?.suspend("com.apple.screenIsLocked", false) }
        observe(Notification.Name("com.apple.screensaver.didstop"), center: distributed) { [weak self] in self?.suspend("com.apple.screensaver.didstart", false) }
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
        power.stop()
        bluetooth.stop()
        alarmStarted = nil
        timer = IslandTimer()
        state = IslandState()
        suspension = []
    }

    private func suspend(_ reason: String, _ value: Bool) {
        if value { suspension.insert(reason) } else { suspension.remove(reason) }
        state.suspended = !suspension.isEmpty
        if state.suspended {
            state.notice = nil
            state.phase = .closed
            panel?.orderOut(nil)
            privateSpace.detach()
            copies.forEach { $0.orderOut(nil) }
            stopCamera()
            calendar.setEnabled(false)
            downloads.setEnabled(false)
            media.stop()
            power.stop()
            bluetooth.stop()
        } else { apply(previous: nil); tick() }
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
        let closedWidth = IslandGeometry.closed(display, settings: settings).width
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
        exploring = false
        layout()
    }

    func select(_ section: IslandSection?) {
        if self.section != section { stopCamera() }
        if section == .system { monitor.popoverDidOpen() }
        if self.section == .system && section != .system { monitor.popoverDidClose() }
        self.section = section
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
              section == nil || visibleSections.contains(section!) else { return }
        state.show(kind, title: title, section: section, now: clock)
        layout()
    }

    func startTimer(mode: IslandTimer.Mode, cycle: IslandTimer.Cycle) {
        timer.start(now: clock, minutes: settings.timerMinutes, mode: mode, cycle: cycle)
        alarmStarted = nil
        tick()
    }

    func acknowledgeTimer() { alarmStarted = nil; state.notice = nil; timer = IslandTimer(); tick() }

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

    private func tick() {
        guard settings.isEnabled, !state.suspended else { return }
        now = clock
        tickCount += 1
        if timer.tick(now: now, suspended: display == nil) {
            notice(.timer, "Timer finished", section: .timer)
            alarmStarted = now
        }
        if let alarmStarted, now - alarmStarted < 300, now - lastAlarm >= 2, settings.timerSound, display != nil {
            NSSound(named: "Glass")?.play()
            lastAlarm = now
        }
        if settings.sections.contains(.music), !(fullScreen && settings.hideInFullScreen) { media.refresh() }
        var activities: [IslandSection] = []
        if timer.active && settings.sections.contains(.timer) { activities.append(.timer) }
        if settings.sections.contains(.downloads), downloads.items.contains(where: { !$0.finished && IslandDownloadLogic.live(modified: $0.modified, now: Date(), published: false) }) { activities.append(.downloads) }
        if settings.sections.contains(.music), music.isPlaying || media.sample?.playing == true { activities.append(.music) }
        if settings.sections.contains(.home), context.keepAwake.isActive { activities.append(.home) }
        if settings.sections.contains(.agents), agents.settings.isEnabled && agents.isReading { activities.append(.agents) }
        if settings.calendarCountdown && settings.sections.contains(.calendar), IslandCalendarLogic.countdown(calendar.events, now: Date()) != nil { activities.append(.calendar) }
        if fullScreen && settings.hideInFullScreen { activities = [] }
        state.activities = activities
        state.refresh(now: now)
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
                    if !self.isOpen || inHeader {
                        let action = self.gesture.consume(x: event.scrollingDeltaX, y: event.scrollingDeltaY, now: self.clock,
                                                          precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice,
                                                          modified: !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                                                          open: self.isOpen, music: self.section == .music)
                        switch action {
                        case .open: self.open()
                        case .close: self.close()
                        case .next: self.music.next()
                        case .previous: self.music.previous()
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
            if settings.sections.contains(.files), context.shelf.settings.isEnabled, board.changeCount != lastDragCount,
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
            if exploring { exploring = false } else { close() }
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
