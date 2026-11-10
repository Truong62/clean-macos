import AppKit
import ApplicationServices
import KeyboardShortcuts
import SwiftUI

enum MediaKeys {
    static let pressed = 0xA
    static let released = 0xB
    static let subtype: Int16 = 8

    static func post(_ code: Int) {
        for state in [pressed, released] {
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: subtype, data1: (code << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

@MainActor
final class RadialMenuController: NSObject, ObservableObject, NSWindowDelegate {
    static let settingsKey = "radial.settings"
    static let panelSize: CGFloat = 400
    static let discSize: CGFloat = 300
    static let chipSize: CGFloat = 52
    static let chipRadius: CGFloat = 112
    static let hubSize: CGFloat = 76
    static let actionDelay: TimeInterval = 0.15
    static let trackInterval: TimeInterval = 1.0 / 60
    static let mouseButtons = 3...31

    @Published var settings: RadialSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            apply(previous: oldValue)
        }
    }
    @Published var highlighted: Int?
    @Published private(set) var navigation = RadialNavigation()
    @Published private(set) var activeWheel: RadialWheel?
    @Published private(set) var conflicts: [RadialTriggerConflict] = []
    var isOpen: Bool { navigation.isOpen }
    var slices: [RadialSlice] { navigation.slices }

    private var tracker: RadialTracker?
    private var center = CGPoint.zero
    private var lastMouse = CGPoint.zero
    private var panel: NSPanel?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var registered = Set<UUID>()
    private var pressedKeys = Set<UUID>()
    private var mousePresses = RadialMousePresses()
    private var targetWindow: AXUIElement?
    private let context: CommandContext
    private let windows: WindowManager

    init(context: CommandContext, windows: WindowManager) {
        self.context = context
        self.windows = windows
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(RadialSettings.self, from: $0) } ?? RadialSettings()
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTap() }
        }
        apply(previous: nil)
    }

    func open(wheelID: UUID? = nil) {
        guard settings.isEnabled, let wheel = settings.wheels.first(where: { wheelID == nil || $0.id == wheelID }) else { return }
        close()
        targetWindow = AXIsProcessTrusted() ? AXWindow.focused() : nil
        let available = actions()
        let visible = RadialAvailability.visible(wheel.slices) { canRun($0, available: available) }
        guard !visible.isEmpty else { return NSSound.beep() }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        activeWheel = wheel
        navigation.open(visible)
        let visibleFrame = screen.visibleFrame
        let half = Self.panelSize / 2
        let wanted = settings.opensAtPointer ? mouse : CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        center = CGPoint(x: min(max(wanted.x, visibleFrame.minX + half), visibleFrame.maxX - half),
                         y: min(max(wanted.y, visibleFrame.minY + half), visibleFrame.maxY - half))
        resetTracking()
        let panel = self.panel ?? KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelSize, height: Self.panelSize),
                                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if panel.contentViewController == nil {
            let host = NSHostingController(rootView: RadialMenuView(controller: self))
            host.sizingOptions = []
            panel.contentViewController = host
        }
        panel.setFrame(NSRect(x: center.x - half, y: center.y - half, width: Self.panelSize, height: Self.panelSize), display: true)
        panel.delegate = self
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: Self.trackInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        installKeyMonitor()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        keyMonitor = nil
        outsideMonitor = nil
        navigation.close()
        targetWindow = nil
        highlighted = nil
        panel?.orderOut(nil)
    }

    func back() {
        navigation.back()
        if !isOpen { close() } else { resetTracking() }
    }

    func release() {
        guard isOpen else { return }
        switch settings.mode {
        case .press: return
        case .pressOrHold:
            if let highlighted { run(highlighted) }
        case .hold:
            if let highlighted { run(highlighted) } else { close() }
        }
    }

    func run(_ index: Int) {
        guard slices.indices.contains(index) else { return }
        let slice = slices[index]
        if case .submenu = slice.action {
            _ = navigation.select(index)
            resetTracking()
            return
        }
        guard canRun(slice.action, available: actions()) else {
            close()
            NSSound.beep()
            return
        }
        let window = targetWindow
        guard let action = navigation.select(index) else { return }
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.actionDelay) { [weak self] in self?.perform(action, window: window) }
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    func actions() -> [CommandItem] { CommandSources.actions(context) }

    func refreshTriggers() {
        let triggers = settings.wheels.map { wheel in
            let shortcut = wheel.keyboardEnabled ? KeyboardShortcuts.getShortcut(for: .radialWheel(wheel.id)) : nil
            return RadialTrigger(wheelID: wheel.id, shortcut: shortcut.map {
                RadialKeystroke(keyCode: UInt16($0.carbonKeyCode), modifiers: UInt64($0.modifiers.rawValue))
            }, mouseButton: wheel.mouseButton)
        }
        conflicts = RadialTriggers.conflicts(triggers)
        KeyboardShortcuts.disable(registered.map { .radialWheel($0) })
        let enabled = RadialTriggers.enabledKeyboardWheels(triggers, isEnabled: settings.isEnabled)
        KeyboardShortcuts.enable(enabled.map { .radialWheel($0) })
        applyTap()
    }

    private func canRun(_ action: RadialSlice.Action, available: [CommandItem]) -> Bool {
        RadialAvailability.canRun(action, commandIDs: Set(available.map(\.id)),
                                  toggleIDs: Set(available.filter { $0.kind == .toggle }.map(\.id)),
                                  hasWindow: targetWindow != nil || !AXIsProcessTrusted() || AXWindow.focused() != nil,
                                  pathExists: { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) })
    }

    private func perform(_ action: RadialSlice.Action, window: AXUIElement?) {
        switch action {
        case .command(let id), .toggle(let id):
            actions().first { $0.id == id }?.run(nil)
        case .app(let path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url }) {
                app.activate()
            } else {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .folder(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        case .link(let text):
            if let url = URL(string: text) { NSWorkspace.shared.open(url) }
        case .media(let code): MediaKeys.post(code)
        case .window(let action):
            guard Self.requestAccessibility() else { return }
            windows.perform(action, window: window)
        case .keystroke(let stroke):
            guard Self.requestAccessibility() else { return }
            Task { @MainActor in
                for _ in 0..<500 {
                    if RadialKeystroke.canPost(heldModifiers: CGEventSource.flagsState(.combinedSessionState).rawValue) {
                        RadialKeyPoster.post(stroke)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        case .submenu: break
        }
    }

    private static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    private func resetTracking() {
        lastMouse = NSEvent.mouseLocation
        tracker = RadialTracker(origin: lastMouse)
        highlighted = nil
    }

    private func track() {
        let mouse = NSEvent.mouseLocation
        guard mouse != lastMouse, var tracker else { return }
        lastMouse = mouse
        let next = tracker.highlight(at: mouse, center: center, count: slices.count)
        self.tracker = tracker
        if tracker.hasMoved && next != highlighted { highlighted = next }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let isHandled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen else { return false }
                if event.type != .keyDown {
                    if self.panel?.frame.contains(NSEvent.mouseLocation) != true { self.close() }
                    return false
                }
                guard self.panel?.windowNumber == event.windowNumber else { return false }
                switch event.keyCode {
                case PanelKeys.escapeKey: self.back()
                case PanelKeys.returnKey, PanelKeys.enterKey:
                    if let highlighted = self.highlighted { self.run(highlighted) }
                case CommandBarKeys.leftKey, PanelKeys.upKey:
                    self.highlighted = RadialSelection.rotate(self.highlighted, by: -1, count: self.slices.count)
                case CommandBarKeys.rightKey, PanelKeys.downKey:
                    self.highlighted = RadialSelection.rotate(self.highlighted, by: 1, count: self.slices.count)
                default:
                    guard let digit = PanelKeys.digitKeys[event.keyCode], let index = RadialSelection.digit(digit, count: self.slices.count) else { return false }
                    self.run(index)
                }
                return true
            }
            return isHandled ? nil : event
        }
    }

    private func apply(previous: RadialSettings?) {
        if previous != nil {
            pressedKeys = []
            if isOpen { close() }
        }
        let ids = Set(settings.wheels.map(\.id))
        for id in registered.subtracting(ids) { KeyboardShortcuts.disable([.radialWheel(id)]) }
        KeyboardShortcuts.disable([.radialMenu])
        for wheel in settings.wheels where registered.insert(wheel.id).inserted {
            let id = wheel.id
            KeyboardShortcuts.disable([.radialWheel(id)])
            KeyboardShortcuts.onKeyDown(for: .radialWheel(id)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.settings.isEnabled,
                          self.settings.wheels.contains(where: { $0.id == id && $0.keyboardEnabled }),
                          !self.conflicts.contains(where: { $0.keyboard && ($0.first == id || $0.second == id) }),
                          self.pressedKeys.insert(id).inserted else { return }
                    if self.isOpen && self.activeWheel?.id == id { self.close() } else { self.open(wheelID: id) }
                }
            }
            KeyboardShortcuts.onKeyUp(for: .radialWheel(id)) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.pressedKeys.remove(id) != nil else { return }
                    if self.activeWheel?.id == id { self.release() }
                }
            }
        }
        if let previous, settings.isEnabled,
           settings.wheels.contains(where: { wheel in
               wheel.mouseButton != nil && (!previous.isEnabled || previous.wheels.first(where: { $0.id == wheel.id })?.mouseButton != wheel.mouseButton)
           }) { _ = Self.requestAccessibility() }
        refreshTriggers()
    }

    private func applyTap() {
        MouseToolsController.reservedButtons = settings.isEnabled ? Set(settings.wheels.compactMap { $0.mouseButton.map { $0 - 1 } }) : []
        let needsTap = mousePresses.hasPendingRelease || (settings.isEnabled && settings.wheels.contains { $0.mouseButton != nil } && AXIsProcessTrusted())
        guard needsTap != (tap != nil) else { return }
        if needsTap { startTap() } else { stopTap() }
    }

    private func startTap() {
        let types: [CGEventType] = [.otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<RadialMenuController>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { controller.handle(type, event) }
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                              callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        let loopSource = CFMachPortCreateRunLoopSource(nil, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        tap = created
        source = loopSource
    }

    private func stopTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        guard !MouseToolsController.capturing, type == .otherMouseDown || type == .otherMouseUp else { return pass }
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
        let triggers = settings.wheels.map { RadialTrigger(wheelID: $0.id, mouseButton: $0.mouseButton) }
        switch mousePresses.handle(button: button, isDown: type == .otherMouseDown, triggers: triggers, isEnabled: settings.isEnabled) {
        case .pass: return pass
        case .swallow: return nil
        case .press(let id):
            if isOpen && activeWheel?.id == id { close() } else { open(wheelID: id) }
        case .release(let id):
            if activeWheel?.id == id { release() }
            applyTap()
        }
        return nil
    }
}

enum RadialKeyPoster {
    static func post(_ stroke: RadialKeystroke) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: down)
            event?.flags = CGEventFlags(rawValue: stroke.modifiers)
            event?.post(tap: .cghidEventTap)
        }
    }
}

extension RadialAccent {
    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .cyan: .cyan
        case .gray: .gray
        }
    }
}

struct RadialWedge: Shape {
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let width = 360 / Double(max(count, 1))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-90 + (Double(index) - 0.5) * width),
                    endAngle: .degrees(-90 + (Double(index) + 0.5) * width), clockwise: false)
        path.closeSubpath()
        return path
    }
}

struct RadialMenuView: View {
    @ObservedObject var controller: RadialMenuController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let slices = controller.slices
        let accent = controller.activeWheel?.accent.color ?? .accentColor
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { controller.close() }
            Circle()
                .fill(.regularMaterial)
                .frame(width: RadialMenuController.discSize, height: RadialMenuController.discSize)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                .onTapGesture { location in
                    let size = RadialMenuController.discSize
                    if let index = RadialGeometry.slice(at: CGPoint(x: location.x, y: size - location.y),
                                                        center: CGPoint(x: size / 2, y: size / 2), count: slices.count) {
                        controller.run(index)
                    }
                }
            if let highlighted = controller.highlighted {
                RadialWedge(index: highlighted, count: slices.count)
                    .fill(LinearGradient(colors: [accent.opacity(0.45), accent.opacity(0.1)], startPoint: .center, endPoint: .top))
                    .frame(width: RadialMenuController.discSize, height: RadialMenuController.discSize)
                    .allowsHitTesting(false)
            }
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                let offset = RadialGeometry.chipOffset(index: index, count: slices.count, radius: RadialMenuController.chipRadius)
                let isHighlighted = controller.highlighted == index
                VStack(spacing: 3) {
                    Image(systemName: slice.symbol).font(.system(size: 18, weight: .semibold))
                    Text(slice.title).font(.system(size: 9, weight: .medium)).lineLimit(1)
                }
                .frame(width: RadialMenuController.chipSize + 18, height: RadialMenuController.chipSize)
                .foregroundStyle(isHighlighted ? accent : .primary)
                .scaleEffect(isHighlighted ? 1.14 : 1)
                .offset(x: offset.x, y: -offset.y)
                .onTapGesture { controller.run(index) }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Circle()
                .fill(.thinMaterial)
                .frame(width: RadialMenuController.hubSize, height: RadialMenuController.hubSize)
                .overlay(Image(systemName: controller.navigation.submenu == nil ? "xmark" : "chevron.left").foregroundStyle(.secondary))
                .onTapGesture { controller.back() }
        }
        .frame(width: RadialMenuController.panelSize, height: RadialMenuController.panelSize)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: controller.highlighted)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.17), value: controller.navigation.submenu?.id)
    }
}
