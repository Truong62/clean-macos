import AppKit
import ApplicationServices
import Carbon
import KeyboardShortcuts
import SwiftUI

@MainActor
final class SwitcherController: ObservableObject {
    static let settingsKey = "switcher.settings"
    @Published var settings: SwitcherSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if !oldValue.isEnabled && settings.isEnabled { requestPermissions(dock: false) }
            if !oldValue.dockEnabled && settings.dockEnabled { requestPermissions(dock: true) }
            if settings.isEnabled && oldValue.layout == .list && settings.layout != .list { requestPermissions(dock: false) }
            cancel()
            cancelDrag()
            hideDock()
            applySettings()
        }
    }
    @Published private(set) var session = SwitcherSession()
    @Published private(set) var dockWindows: [SwitcherWindow] = []
    @Published private(set) var accessibility = false
    @Published private(set) var screenRecording = false
    @Published private(set) var notice = ""
    @Published private(set) var dockBlocked = ""
    @Published private(set) var dockGeometry = DockGeometry()
    @Published private(set) var quitting = Set<Int32>()
    @Published private(set) var closing = Set<String>()
    @Published var hovered: String?
    let thumbnails = SwitcherThumbnails()
    let activation = SwitcherActivation()
    let takeover = SwitcherTakeover()
    private var history = SwitcherHistory()
    private let focusObserver = SwitcherFocusObserver()
    private var screenLocked = false
    private var elements: [String: AXUIElement] = [:]
    private var mode = SwitcherMode.apps
    private var frontPID: Int32?
    private var sourceID: String?
    private var required: CGEventFlags = .maskCommand
    private var lastFlags: CGEventFlags = []
    private var shiftTime: TimeInterval = -.infinity
    private var scroll = SwitcherScroll()
    private var shownPoint = CGPoint.zero
    private var screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private var generation = UUID()
    private var enumeration: Task<Void, Never>?
    private var pins: [SwitcherPinnedPreview] = []
    private var ghost: SwitcherPanel?
    private var dragging: SwitcherWindow?
    private var panel: SwitcherPanel?
    private var dockPanel: SwitcherPanel?
    private var openTask: Task<Void, Never>?
    private var dockTask: Task<Void, Never>?
    private var dockHideTask: Task<Void, Never>?
    private var dockHitTask: Task<Void, Never>?
    private var dockTarget: DockPreviewTarget?
    private var hoverState = DockHoverState()
    private var dockGeneration = UUID()
    private var dockPoint = CGPoint.zero
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var sessionActive = true
    private var recordingShortcut = false
    private var secureInput = false
    private var dockPreferencesAt: TimeInterval = -.infinity
    private var permissionAt: TimeInterval = -.infinity
    private var commitAfterClose = false
    private var warmTask: Task<Void, Never>?
    private lazy var events = SwitcherEventTap { [weak self] input in
        DispatchQueue.main.async { self?.receive(input) }
    }
    private lazy var dockEvents = SwitcherEventTap(listenOnly: true) { [weak self] input in
        DispatchQueue.main.async { self?.receiveDock(input) }
    }

    init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(SwitcherSettings.self, from: $0) } ?? SwitcherSettings()
        KeyboardShortcuts.disable([.switcherApps, .switcherCurrentApp, .switcherAllWindows])
        focusObserver.onFocus = { [weak self] id, pid in self?.history.focus(id, pid: pid) }
        observe(.init("KeyboardShortcuts_recorderActiveStatusDidChange")) { controller, note in
            controller.recordingShortcut = note.userInfo?["isActive"] as? Bool ?? false
            if controller.recordingShortcut { controller.cancel() }
            controller.applySettings()
        }
        observe(.init("com.apple.screenIsLocked"), center: DistributedNotificationCenter.default()) { controller, _ in
            controller.screenLocked = true
            controller.thumbnails.active = false
            controller.cancel()
            controller.cancelDrag()
            controller.hideDock()
            controller.applySettings()
        }
        observe(.init("com.apple.screenIsUnlocked"), center: DistributedNotificationCenter.default()) { controller, _ in
            controller.screenLocked = false
            controller.thumbnails.active = controller.sessionActive
            controller.applySettings()
        }
        observe(NSApplication.willTerminateNotification) { controller, _ in controller.shutdown() }
        observe(NSApplication.didBecomeActiveNotification) { controller, _ in controller.applySettings() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.didActivateApplicationNotification, center: workspace) { controller, note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            controller.history.activate(app.processIdentifier)
            controller.warm(app)
        }
        observe(NSWorkspace.didTerminateApplicationNotification, center: workspace) { controller, note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            controller.removeApp(app.processIdentifier)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(name, center: workspace) { controller, _ in
                controller.sessionActive = false
                controller.thumbnails.active = false
                controller.cancel()
                controller.cancelDrag()
                controller.hideDock()
                controller.takeover.restore()
                controller.events.stop()
                controller.dockEvents.stop()
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(name, center: workspace) { controller, _ in
                controller.sessionActive = true
                controller.thumbnails.active = !controller.screenLocked
                controller.applySettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak controller] in controller?.applySettings() }
            }
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { controller, _ in
            if controller.settings.dockCurrentDesktopOnly { controller.hideDock() }
        }
        applySettings()
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter = .default,
                         action: @escaping @MainActor (SwitcherController, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { if let self { action(self, note) } }
        }
        observers.append((center, token))
    }

    func shortcutChanged(_ shortcut: KeyboardShortcuts.Shortcut?, name: KeyboardShortcuts.Name, mode: SwitcherMode) {
        KeyboardShortcuts.disable([name])
        if let shortcut, !SwitcherTrigger.allowed(mode: mode, key: UInt16(shortcut.carbonKeyCode), flags: CGEventFlags(rawValue: UInt64(shortcut.modifiers.rawValue))) {
            let key: KeyboardShortcuts.Key = mode == .currentApp ? .backtick : .tab
            KeyboardShortcuts.setShortcut(.init(key, modifiers: mode == .allWindows ? [.option] : [.command]), for: name)
            notice = "Use the macOS switcher combination for this role, with optional Shift."
        }
        cancel()
        applySettings()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        applySettings()
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        permissionAt = -.infinity
        applySettings()
    }

    private func requestPermissions(dock: Bool) {
        if !AXIsProcessTrusted() { requestAccessibility() }
        if (dock || settings.layout != .list) && !CGPreflightScreenCaptureAccess() { requestScreenRecording() }
    }

    private var triggers: [SwitcherTrigger] {
        guard settings.isEnabled else { return [] }
        let pairs: [(KeyboardShortcuts.Name, SwitcherMode)] = [(.switcherApps, .apps), (.switcherCurrentApp, .currentApp), (.switcherAllWindows, .allWindows)]
        return pairs.compactMap { name, mode in
            if mode == .allWindows && !settings.allWindowsEnabled { return nil }
            guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return nil }
            let flags = CGEventFlags(rawValue: UInt64(shortcut.modifiers.rawValue))
            return SwitcherTrigger(mode: mode, key: UInt16(shortcut.carbonKeyCode), modifiers: flags)
        }
    }

    private func applySettings() {
        accessibility = AXIsProcessTrusted()
        let now = ProcessInfo.processInfo.systemUptime
        if now - permissionAt >= 5 {
            screenRecording = CGPreflightScreenCaptureAccess()
            permissionAt = now
        }
        secureInput = IsSecureEventInputEnabled()
        let usable = accessibility && sessionActive && !screenLocked && !secureInput && !recordingShortcut
        focusObserver.watch(usable && (settings.isEnabled || settings.dockEnabled) ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil)
        events.configure(.init(triggers: usable ? triggers : [], recording: recordingShortcut, session: usable && session.phase != .idle))
        if usable && settings.isEnabled {
            events.start()
            if panel == nil { panel = makePanel(dock: false) }
        } else {
            events.stop()
            if session.phase != .idle { cancel() }
        }
        notice = !accessibility ? "Accessibility access is required to switch windows."
            : secureInput ? "Secure input is active. Native shortcuts are restored; search and window commands are paused."
            : settings.takeover && !takeover.available ? "System shortcut takeover is unavailable on this macOS version. Native shortcuts remain enabled." : ""
        takeover.reconcile(triggers: triggers, permitted: settings.takeover && usable && events.isLive)
        if now - dockPreferencesAt >= 10 {
            if let preferences = DockPreviewAccess.preferences() { dockGeometry = preferences; dockBlocked = "" }
            else { dockBlocked = "The Dock process or its preferences are unavailable." }
            dockPreferencesAt = now
        }
        if !accessibility { dockBlocked = "Dock preview requires Accessibility access." }
        else if !screenRecording { dockBlocked = "Dock preview requires Screen Recording access." }
        else if dockBlocked == "Dock preview requires Accessibility access." || dockBlocked == "Dock preview requires Screen Recording access." {
            dockBlocked = DockPreviewAccess.preferences() == nil ? "The Dock process or its preferences are unavailable." : ""
        }
        let dockUsable = settings.dockEnabled && usable && screenRecording && dockBlocked.isEmpty
        dockEvents.configure(.init(dock: dockUsable))
        if dockUsable { dockEvents.start() }
        else { dockEvents.stop(); hideDock() }
        if settings.isEnabled || settings.dockEnabled {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applySettings() }
                }
            }
        } else { timer?.invalidate(); timer = nil }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        focusObserver.stop()
        warmTask?.cancel()
        for pin in pins { pin.close() }
        ghost?.orderOut(nil)
        cancel()
        hideDock()
        events.stop()
        dockEvents.stop()
        takeover.restore()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    func openFromCommandBar() {
        guard settings.isEnabled else { return }
        if !accessibility { requestAccessibility(); return }
        begin(.apps, reverse: false, required: [])
        session.pinned = true
    }

    private func begin(_ mode: SwitcherMode, reverse: Bool, required: CGEventFlags) {
        guard settings.isEnabled, accessibility, sessionActive, !screenLocked, !secureInput else { events.setSession(false); return }
        hideDock()
        activation.cancel()
        self.mode = mode
        self.required = required
        lastFlags = required.union(reverse ? .maskShift : [])
        shiftTime = -.infinity
        scroll = SwitcherScroll()
        frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        shownPoint = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(shownPoint) } ?? NSScreen.main
        let placementScreen: NSScreen?
        if settings.placement == .menuBar { placementScreen = NSScreen.screens.first }
        else if settings.placement == .frontWindow, let focused = AXWindow.focused(), let frame = AXWindow.frame(focused),
                let index = WindowGeometry.screenIndex(for: frame, screens: AXWindow.screens()), NSScreen.screens.indices.contains(index) {
            placementScreen = NSScreen.screens[index]
        } else { placementScreen = pointerScreen }
        screen = (placementScreen ?? pointerScreen)?.visibleFrame ?? screen
        session.begin(reverse: reverse)
        events.setSession(true)
        generation = UUID()
        let token = generation
        let started = ProcessInfo.processInfo.systemUptime
        enumeration = Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.snapshot()
            guard !Task.isCancelled, self.generation == token else { return }
            self.elements.merge(snapshot.elements) { _, new in new }
            self.thumbnails.prune(Set(snapshot.windows.map(\.id)))
            self.history.prune(ids: Set(snapshot.windows.map(\.id)), pids: Set(snapshot.windows.map(\.pid)))
            self.sourceID = snapshot.focused
            if let focused = snapshot.focused, let entry = snapshot.windows.first(where: { $0.id == focused }) {
                self.history.focus(focused, pid: entry.pid)
            }
            let entries = self.filtered(snapshot, mode: mode)
            let commit = self.session.arrive(entries, frontPID: self.frontPID, grouped: self.settings.layout != .previews && mode == .apps)
            guard !entries.isEmpty else { self.cancel(); return }
            if commit { self.commit(); return }
            let remaining = max(0, Double(self.settings.showDelay) / 1000 - (ProcessInfo.processInfo.systemUptime - started))
            self.openTask = Task {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled, self.generation == token, self.session.phase == .browsing else { return }
                self.showPanel()
            }
            self.thumbnails.refresh(entries, size: self.settings.size, dock: false, simple: self.settings.layout == .list, pausedApps: self.settings.pausedApps)
        }
    }

    private func snapshot(pid: Int32? = nil) async -> SwitcherWindowSnapshot {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && (pid == nil || $0.processIdentifier == pid) }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return await Task.detached(priority: .userInitiated) { SwitcherWindowAccess.snapshot(apps: apps, frontPID: front) }.value
    }

    private func filtered(_ snapshot: SwitcherWindowSnapshot, mode: SwitcherMode, dock: Bool = false, pid: Int32? = nil) -> [SwitcherWindow] {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let display = CGRect(x: screen.minX, y: height - screen.maxY, width: screen.width, height: screen.height)
        return SwitcherFilter.list(snapshot.windows, settings: settings, mode: mode, frontPID: pid ?? frontPID,
                                   display: display, history: history, focused: snapshot.focused, dock: dock)
    }

    var displayed: [SwitcherWindow] {
        let entries = session.visible
        guard settings.layout != .previews && mode == .apps else { return entries }
        var pids = Set<Int32>()
        return entries.filter { pids.insert($0.pid).inserted }
    }

    var selectedAppWindows: [SwitcherWindow] {
        guard let pid = session.selected?.pid else { return [] }
        return session.visible.filter { $0.pid == pid }
    }

    var grid: SwitcherGrid {
        SwitcherGrid.make(count: displayed.count, layout: settings.layout, scale: settings.size.scale, cap: settings.columns, screen: screen.size)
    }

    private func makePanel(dock: Bool) -> SwitcherPanel {
        let panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.setAccessibilitySubrole(NSAccessibility.Subrole(rawValue: "AXUnknown"))
        let host = NSHostingController(rootView: SwitcherPanelView(controller: self, thumbnails: thumbnails, dock: dock))
        host.sizingOptions = []
        panel.contentViewController = host
        return panel
    }

    private func showPanel() {
        if panel == nil { panel = makePanel(dock: false) }
        let base = grid.panel
        let extra: CGFloat = settings.layout == .icons ? 184 * settings.size.scale : 0
        let size = CGSize(width: max(min(screen.width * 0.92, 480 * settings.size.scale), base.width), height: min(screen.height * 0.85, base.height + extra))
        panel?.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height), display: false)
        panel?.orderFrontRegardless()
    }

    func cancel() {
        generation = UUID()
        enumeration?.cancel()
        openTask?.cancel()
        thumbnails.cancel()
        session.cancel()
        events.setSession(false)
        panel?.orderOut(nil)
        hovered = nil
        commitAfterClose = false
    }

    func commit(_ explicit: SwitcherWindow? = nil) {
        guard closing.isEmpty else { commitAfterClose = true; return }
        let target = explicit ?? session.selected
        let source = sourceID
        cancel()
        hideDock()
        guard let target, !quitting.contains(target.pid) else { return }
        history.focus(target.id, pid: target.pid, source: source)
        activation.activate(target, element: elements[target.id])
    }

    func select(_ window: SwitcherWindow, hover: Bool = false) {
        if hover {
            guard !settings.ignoreHover, hypot(NSEvent.mouseLocation.x - shownPoint.x, NSEvent.mouseLocation.y - shownPoint.y) > 4 else { return }
        }
        if let index = session.visible.firstIndex(where: { $0.id == window.id }) { session.selection = index }
    }

    private func step(_ delta: Int, repeating: Bool = false) {
        if settings.layout != .previews && mode == .apps, session.phase == .browsing,
           let selected = session.selected, let index = displayed.firstIndex(where: { $0.pid == selected.pid }), !displayed.isEmpty {
            let next = repeating ? min(displayed.count - 1, max(0, index + delta)) : ((index + delta) % displayed.count + displayed.count) % displayed.count
            select(displayed[next])
        } else { session.step(delta, repeating: repeating) }
    }

    private func cycleWindow(_ delta: Int) {
        let windows = selectedAppWindows
        guard let id = session.selected?.id, let index = windows.firstIndex(where: { $0.id == id }), !windows.isEmpty else { return }
        select(windows[((index + delta) % windows.count + windows.count) % windows.count])
    }

    private func receive(_ input: SwitcherInput) {
        switch input {
        case .trigger(let mode, let reverse, let repeating, let required):
            if session.phase == .idle { begin(mode, reverse: reverse, required: required) }
            else if mode == .currentApp && self.mode == .apps && session.phase == .browsing { cycleWindow(reverse ? -1 : 1) }
            else if ProcessInfo.processInfo.systemUptime - shiftTime > 0.35 { step(reverse ? -1 : 1, repeating: repeating) }
        case .modifiers(let flags):
            if session.phase == .idle { return }
            if !flags.intersection(required).isSuperset(of: required) {
                if session.release() { commit() }
            } else if !required.contains(.maskShift), flags.contains(.maskShift), !lastFlags.contains(.maskShift) {
                shiftTime = ProcessInfo.processInfo.systemUptime
                step(-1)
            }
            lastFlags = flags
        case .key(let key, let text, let flags, let repeating):
            activation.cancel()
            guard session.phase != .idle else { return }
            guard session.phase == .browsing else {
                if flags.intersection(required) != required { cancel() }
                return
            }
            switch key {
            case 53: cancel()
            case 36, 76: commit()
            case 123: step(-1)
            case 124: step(1)
            case 125: settings.layout == .previews ? session.row(1, columns: grid.columns) : cycleWindow(1)
            case 126: settings.layout == .previews ? session.row(-1, columns: grid.columns) : cycleWindow(-1)
            case 51: session.search(String(session.query.dropLast()))
            case 48: step(flags.contains(.maskShift) ? -1 : 1, repeating: repeating)
            default:
                let character = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if session.query.isEmpty && !session.pinned {
                    if character == "w" || (key == 13 && character.unicodeScalars.contains { !$0.isASCII }) {
                        if !repeating, let window = session.selected { close(window) }
                        return
                    }
                    if character == "q" || (key == 12 && character.unicodeScalars.contains { !$0.isASCII }) {
                        if !repeating, let window = session.selected { quit(window) }
                        return
                    }
                    if settings.pinSearch && character == "s" { if !repeating { session.pinned = true }; return }
                }
                if !text.isEmpty && text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    session.search(session.query + text)
                }
            }
        case .scroll(let x, let y, let continuous, let momentum):
            let delta = scroll.steps(x: x, y: y, continuous: continuous, momentum: momentum, now: ProcessInfo.processInfo.systemUptime)
            if delta != 0 { step(delta, repeating: true) }
        case .pointer(let point, let down, let middle):
            if down {
                activation.cancel()
                let appKitPoint = appKit(point)
                if panel?.isVisible == true, panel?.frame.contains(appKitPoint) == true {
                    if middle, let id = hovered, let window = session.visible.first(where: { $0.id == id }) { close(window) }
                } else { cancel() }
            }
        case .activity:
            activation.cancel()
        case .dragEnded:
            finishDrag()
        case .interrupted:
            cancel()
            takeover.restore()
            if settings.isEnabled && accessibility { notice = "The keyboard event tap stopped. Native shortcuts have been restored." }
        }
    }

    func close(_ window: SwitcherWindow) {
        guard let element = elements[window.id], closing.insert(window.id).inserted else { return }
        Task {
            if window.fullScreen {
                AXUIElementSetAttributeValue(element, "AXFullScreen" as CFString, kCFBooleanFalse)
                for _ in 0..<40 {
                    if (AXWindow.value(element, "AXFullScreen") as Bool?) != true { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let app = NSRunningApplication(processIdentifier: window.pid)
            if window.hidden { app?.unhide() }
            SwitcherWindowAccess.close(element)
            for delay in [180, 350, 350] {
                try? await Task.sleep(for: .milliseconds(delay))
                let fresh = await snapshot(pid: window.pid)
                let remains = fresh.windows.contains { $0.id == window.id }
                updateApp(window.pid, snapshot: fresh)
                if !remains { break }
            }
            closing.remove(window.id)
            if window.hidden, !session.entries.contains(where: { $0.id == window.id }) { app?.hide() }
            if commitAfterClose && closing.isEmpty { commit() }
        }
    }

    func quit(_ window: SwitcherWindow) {
        guard window.bundleID != "com.apple.finder", !quitting.contains(window.pid),
              let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        quitting.insert(window.pid)
        app.terminate()
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            quitting.remove(window.pid)
        }
    }

    func minimize(_ window: SwitcherWindow) {
        guard !window.fullScreen, let element = elements[window.id] else { return }
        SwitcherWindowAccess.minimize(element, value: !window.minimized)
        Task {
            for delay in [40, 80, 160, 270] {
                try? await Task.sleep(for: .milliseconds(delay))
                let value: Bool? = AXWindow.value(element, kAXMinimizedAttribute)
                if value == !window.minimized {
                    updateApp(window.pid, snapshot: await snapshot(pid: window.pid))
                    return
                }
            }
        }
    }

    private func updateApp(_ pid: Int32, snapshot: SwitcherWindowSnapshot) {
        elements.merge(snapshot.elements) { _, new in new }
        if session.phase == .browsing {
            let remaining = session.entries.filter { $0.pid != pid } + filtered(snapshot, mode: mode)
            session.replace(history.ordered(remaining, focused: sourceID))
            if session.entries.isEmpty { cancel() }
        }
        if hoverState.visiblePID == pid {
            dockWindows = filtered(snapshot, mode: .currentApp, dock: true, pid: pid)
            if dockWindows.isEmpty { hideDock() } else { placeDock() }
        }
    }

    private func removeApp(_ pid: Int32) {
        session.replace(session.entries.filter { $0.pid != pid })
        quitting.remove(pid)
        if session.phase == .browsing && session.entries.isEmpty { cancel() }
        if hoverState.visiblePID == pid { hideDock() }
    }

    private func appKit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }

    private func warm(_ app: NSRunningApplication) {
        warmTask?.cancel()
        guard settings.isEnabled || settings.dockEnabled, accessibility, sessionActive else { return }
        warmTask = Task {
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, session.phase == .idle, dockWindows.isEmpty else { return }
            let snapshot = await snapshot(pid: app.processIdentifier)
            guard !Task.isCancelled else { return }
            if let id = snapshot.focused { history.focus(id, pid: app.processIdentifier) }
            thumbnails.refresh(snapshot.windows, size: settings.size, dock: false, simple: settings.layout == .list, pausedApps: settings.pausedApps)
        }
    }

    private func receiveDock(_ input: SwitcherInput) {
        guard settings.dockEnabled, accessibility, screenRecording, sessionActive, !screenLocked else { return }
        if case .dragEnded = input { finishDrag(); return }
        guard case .pointer(let point, let down, let middle) = input else {
            if case .interrupted = input { hideDock() }
            return
        }
        dockPoint = point
        if dragging != nil { ghost?.setFrameOrigin(appKit(point)); return }
        if down {
            if dockPanel?.frame.contains(appKit(point)) == true {
                if middle, let window = dockWindows.first(where: { $0.id == hovered }) { close(window) }
            } else { hideDock() }
            return
        }
        if dockPanel?.isVisible == true, dockPanel?.frame.insetBy(dx: -6, dy: -6).contains(appKit(point)) == true {
            hoverState.enteredPanel = true
            dockHideTask?.cancel()
            dockHideTask = nil
            return
        }
        guard session.phase == .idle, dockHitTask == nil else { return }
        dockHitTask = Task {
            try? await Task.sleep(for: .seconds(1.0 / 60))
            guard !Task.isCancelled else { return }
            let latest = dockPoint
            let target = await hitDock(latest)
            guard !Task.isCancelled else { return }
            dockHitTask = nil
            handleDockTarget(target, point: latest)
        }
    }

    private func hitDock(_ point: CGPoint) async -> DockPreviewTarget? {
        let geometry = dockGeometry
        let screens = NSScreen.screens.map { screen in
            CGRect(x: screen.frame.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
        }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return await Task.detached(priority: .userInitiated) { DockPreviewAccess.target(at: point, geometry: geometry, screens: screens, apps: apps) }.value
    }

    private func handleDockTarget(_ target: DockPreviewTarget?, point: CGPoint) {
        guard settings.dockEnabled, session.phase == .idle else { return }
        if let target {
            dockHideTask?.cancel()
            dockHideTask = nil
            if target.pid == hoverState.visiblePID {
                if hoverState.enteredPanel { hideDock() }
                return
            }
            let previous = hoverState.deadline
            hoverState.hover(pid: target.pid, point: point, now: ProcessInfo.processInfo.systemUptime, delay: Double(settings.dockDelay) / 1000)
            guard hoverState.deadline != previous else { return }
            dockTask?.cancel()
            let token = UUID()
            dockGeneration = token
            dockTask = Task {
                let deadline = hoverState.deadline ?? 0
                let prefetch = max(0, deadline - ProcessInfo.processInfo.systemUptime - 0.1)
                try? await Task.sleep(for: .seconds(prefetch))
                guard !Task.isCancelled else { return }
                let snapshot = await snapshot(pid: target.pid)
                let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
                try? await Task.sleep(for: .seconds(remaining))
                let confirmed = await hitDock(dockPoint)
                guard !Task.isCancelled, token == dockGeneration,
                      hoverState.open(now: ProcessInfo.processInfo.systemUptime, confirmedPID: confirmed?.pid) else { return }
                dockWindows = filtered(snapshot, mode: .currentApp, dock: true, pid: target.pid)
                guard !dockWindows.isEmpty else { hideDock(); return }
                elements.merge(snapshot.elements) { _, new in new }
                dockTarget = confirmed
                if dockPanel == nil { dockPanel = makePanel(dock: true) }
                placeDock()
                dockPanel?.orderFrontRegardless()
                thumbnails.refresh(dockWindows, size: settings.dockSize, dock: true, simple: false, pausedApps: settings.dockPausedApps)
            }
        } else {
            if let icon = dockTarget?.frame, let frame = dockPanel?.frame, !hoverState.enteredPanel {
                let panelAX = CGRect(x: frame.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - frame.maxY, width: frame.width, height: frame.height)
                if dockGeometry.inOpeningPath(point, icon: icon, panel: panelAX) { return }
            }
            hoverState.hover(pid: nil, point: point, now: 0, delay: 0)
            dockTask?.cancel()
            guard dockHideTask == nil else { return }
            dockHideTask = Task {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                dockHideTask = nil
                if dockPanel?.frame.insetBy(dx: -6, dy: -6).contains(appKit(dockPoint)) != true { hideDock() }
            }
        }
    }

    private func placeDock() {
        guard let icon = dockTarget?.frame else { return }
        let center = appKit(CGPoint(x: icon.midX, y: icon.midY))
        guard let display = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return }
        let visible = display.visibleFrame
        let height = NSScreen.screens.first?.frame.height ?? 0
        let axVisible = CGRect(x: visible.minX, y: height - visible.maxY, width: visible.width, height: visible.height)
        let size = dockGeometry.panelSize(count: dockWindows.count, size: settings.dockSize, screen: visible.size)
        let frame = dockGeometry.placement(icon: icon, panel: size, visible: axVisible)
        dockPanel?.setFrame(CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height), display: false)
        dockPanel?.alphaValue = 1
    }

    func pin(_ window: SwitcherWindow) {
        let preview = SwitcherPinnedPreview(window: window, controller: self)
        pins.append(preview)
        let point = dockPanel?.frame.origin ?? NSEvent.mouseLocation
        preview.show(at: point)
        hideDock()
    }

    func removePin(_ id: UUID) { pins.removeAll { $0.id == id } }

    func refreshPinned(pid: Int32) async -> [SwitcherWindow] {
        guard settings.dockEnabled, accessibility, screenRecording, sessionActive, !screenLocked else { return [] }
        let fresh = await snapshot(pid: pid)
        elements.merge(fresh.elements) { _, new in new }
        let windows = filtered(fresh, mode: .currentApp, dock: true, pid: pid)
        if session.phase == .idle && dockWindows.isEmpty {
            thumbnails.refresh(windows, size: settings.dockSize, dock: true, simple: false, pausedApps: settings.dockPausedApps)
        }
        return windows
    }

    func activatePinned(_ window: SwitcherWindow) {
        history.focus(window.id, pid: window.pid)
        activation.activate(window, element: elements[window.id])
    }

    func drag(_ window: SwitcherWindow) {
        guard !window.fullScreen, let image = thumbnails.images[window.id] else { return }
        if ghost == nil {
            let ghost = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            ghost.level = .statusBar
            ghost.backgroundColor = .clear
            ghost.isOpaque = false
            ghost.ignoresMouseEvents = true
            ghost.alphaValue = 0.55
            ghost.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let size = CGSize(width: image.size.width * 0.22, height: image.size.height * 0.22)
            ghost.contentView = NSHostingView(rootView: Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: size.width, height: size.height))
            ghost.setContentSize(size)
            self.ghost = ghost
            dragging = window
            hideDock()
        }
        ghost?.setFrameOrigin(NSEvent.mouseLocation)
        ghost?.orderFrontRegardless()
    }

    private func cancelDrag() {
        ghost?.orderOut(nil)
        ghost = nil
        dragging = nil
    }

    func finishDrag() {
        ghost?.orderOut(nil)
        ghost = nil
        guard let window = dragging else { return }
        dragging = nil
        guard let element = elements[window.id] else { return }
        let point = AXWindow.toAX(NSEvent.mouseLocation)
        let screens = AXWindow.screens()
        guard let screen = screens.first(where: { $0.contains(point) }) ?? screens.first else { return }
        let frame = PreviewDragGeometry.placed(window: window.frame, pointer: point, visible: screen)
        NSRunningApplication(processIdentifier: window.pid)?.unhide()
        AXWindow.setFrame(frame, of: element)
        activatePinned(window)
    }

    func hideDock() {
        if session.phase == .idle { thumbnails.cancel() }
        dockGeneration = UUID()
        dockTask?.cancel()
        dockHideTask?.cancel()
        dockHitTask?.cancel()
        dockTask = nil
        dockHideTask = nil
        dockHitTask = nil
        dockPanel?.orderOut(nil)
        dockWindows = []
        hoverState.close()
        dockTarget = nil
        hovered = nil
    }
}

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
