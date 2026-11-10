import AppKit
import ApplicationServices

@MainActor
final class SnapPreview {
    private var panel: NSPanel?

    func show(_ axFrame: CGRect) {
        let height = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: axFrame.minX, y: height - axFrame.maxY, width: axFrame.width, height: axFrame.height)
        let panel = panel ?? makePanel()
        panel.setFrame(frame.insetBy(dx: 4, dy: 4), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        view.layer?.borderWidth = 2
        panel.contentView = view
        return panel
    }
}

@MainActor
final class WindowMouseHandler {
    static let titleBarHeight: CGFloat = 40
    static let zoomSubroles: Set<String> = ["AXZoomButton", "AXFullScreenButton"]

    weak var manager: WindowManager?
    private var settings = WindowManager.Settings()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let preview = SnapPreview()
    private var snapWindow: AXUIElement?
    private var snapAction: WindowAction?
    private var drag: (window: AXUIElement, start: CGPoint, frame: CGRect, resizes: Bool)?
    private var swallowUp = false

    func update(_ settings: WindowManager.Settings) {
        self.settings = settings
        let needed = settings.snapsToEdges || settings.dragsWithModifiers || settings.greenButtonMaximizes || settings.dockClick != .none
        if needed && tap == nil && AXIsProcessTrusted() { start() } else if !needed { stop() }
    }

    private func start() {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let handler = Unmanaged<WindowMouseHandler>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { handler.handle(type, event) }
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                              callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let loopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = loopSource
    }

    private func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        preview.hide()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .leftMouseDown:
            return mouseDown(event) ? nil : pass
        case .leftMouseDragged:
            return mouseDragged(event) ? nil : pass
        case .leftMouseUp:
            return mouseUp(event) ? nil : pass
        default:
            return pass
        }
    }

    private func mouseDown(_ event: CGEvent) -> Bool {
        let point = event.location
        let flags = event.flags
        if settings.dragsWithModifiers, flags.contains(.maskControl), flags.contains(.maskCommand),
           let window = AXWindow.at(point), let frame = AXWindow.frame(window) {
            drag = (window, point, frame, flags.contains(.maskShift))
            return true
        }
        guard let element = elementAt(point) else { return false }
        let subrole: String? = AXWindow.value(element, kAXSubroleAttribute)
        if settings.greenButtonMaximizes, !flags.contains(.maskAlternate), let subrole, Self.zoomSubroles.contains(subrole),
           let window: AXUIElement = AXWindow.value(element, kAXWindowAttribute) {
            toggleMaximize(window)
            swallowUp = true
            return true
        }
        if settings.dockClick != .none, handleDockClick(element) {
            swallowUp = true
            return true
        }
        if settings.snapsToEdges, let window = AXWindow.at(point), let frame = AXWindow.frame(window), point.y - frame.minY <= Self.titleBarHeight {
            snapWindow = window
        }
        return false
    }

    private func mouseDragged(_ event: CGEvent) -> Bool {
        let point = event.location
        if let drag {
            let dx = point.x - drag.start.x
            let dy = point.y - drag.start.y
            let frame = drag.resizes
                ? CGRect(origin: drag.frame.origin, size: CGSize(width: max(200, drag.frame.width + dx), height: max(120, drag.frame.height + dy)))
                : drag.frame.offsetBy(dx: dx, dy: dy)
            AXWindow.setFrame(frame, of: drag.window)
            return true
        }
        guard snapWindow != nil else { return false }
        let screens = AXWindow.screens()
        guard let screen = screens.first(where: { $0.insetBy(dx: -1, dy: -30).contains(point) }),
              let action = WindowGeometry.snapAction(cursor: point, screen: screen),
              let target = WindowGeometry.frame(for: action, screen: screen, window: .zero, gap: CGFloat(settings.gap)) else {
            snapAction = nil
            preview.hide()
            return false
        }
        snapAction = action
        preview.show(target)
        return false
    }

    private func mouseUp(_ event: CGEvent) -> Bool {
        if drag != nil {
            drag = nil
            return true
        }
        if swallowUp {
            swallowUp = false
            return true
        }
        if let window = snapWindow, let action = snapAction {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.manager?.perform(action, window: window)
            }
        }
        snapWindow = nil
        snapAction = nil
        preview.hide()
        return false
    }

    private func elementAt(_ point: CGPoint) -> AXUIElement? {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success else { return nil }
        return element
    }

    private func toggleMaximize(_ window: AXUIElement) {
        guard let frame = AXWindow.frame(window), let screen = WindowGeometry.screenIndex(for: frame, screens: AXWindow.screens()),
              let maximized = WindowGeometry.frame(for: .maximize, screen: AXWindow.screens()[screen], window: frame, gap: CGFloat(settings.gap)) else { return }
        let isMaximized = abs(frame.width - maximized.width) < 4 && abs(frame.height - maximized.height) < 4
        manager?.perform(isMaximized ? .restore : .maximize, window: window)
    }

    private func handleDockClick(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock",
              (AXWindow.value(element, kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
              let title: String = AXWindow.value(element, kAXTitleAttribute),
              let front = NSWorkspace.shared.frontmostApplication, front.localizedName == title else { return false }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        let windows: [AXUIElement] = AXWindow.value(app, kAXWindowsAttribute) ?? []
        switch settings.dockClick {
        case .none:
            return false
        case .hide:
            front.hide()
        case .minimize:
            windows.forEach { AXUIElementSetAttributeValue($0, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
        case .cycle:
            guard windows.count > 1 else { return false }
            AXUIElementPerformAction(windows[windows.count - 1], kAXRaiseAction as CFString)
        }
        return true
    }
}

@MainActor
final class LastWindowQuitter {
    static let checkDelay: TimeInterval = 0.4

    private var observers: [pid_t: AXObserver] = [:]
    private var exceptions: Set<String> = []
    private var isEnabled = false
    private var launchObserver: NSObjectProtocol?

    func update(enabled: Bool, exceptions: Set<String>) {
        self.exceptions = exceptions
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled && AXIsProcessTrusted() {
            NSWorkspace.shared.runningApplications.forEach(observe)
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    guard let self, let app else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.observe(app) }
                }
            }
        } else {
            observers.values.forEach { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource($0), .defaultMode) }
            observers.removeAll()
            if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
            launchObserver = nil
        }
    }

    private func observe(_ app: NSRunningApplication) {
        guard isEnabled, app.activationPolicy == .regular, observers[app.processIdentifier] == nil,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let pid = app.processIdentifier
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let quitter = Unmanaged<LastWindowQuitter>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { quitter.notified(element, name: name) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let element = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, refcon)
        (AXWindow.value(element, kAXWindowsAttribute) as [AXUIElement]? ?? []).forEach {
            AXObserverAddNotification(observer, $0, kAXUIElementDestroyedNotification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func notified(_ element: AXUIElement, name: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if name == kAXWindowCreatedNotification, let observer = observers[pid] {
            AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.checkDelay) { [weak self] in
            self?.quitIfEmpty(pid)
        }
    }

    private func quitIfEmpty(_ pid: pid_t) {
        guard isEnabled, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              !exceptions.contains(app.bundleIdentifier ?? "") else { return }
        let windows: [AXUIElement] = AXWindow.value(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
        if windows.isEmpty {
            app.terminate()
            observers[pid] = nil
        }
    }
}
