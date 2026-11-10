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
    @Published private(set) var isOpen = false

    private var tracker: RadialTracker?
    private var center = CGPoint.zero
    private var lastMouse = CGPoint.zero
    private var panel: NSPanel?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let context: CommandContext

    init(context: CommandContext) {
        self.context = context
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(RadialSettings.self, from: $0) } ?? RadialSettings()
        super.init()
        KeyboardShortcuts.onKeyDown(for: .radialMenu) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isOpen { self.close() } else { self.open() }
            }
        }
        KeyboardShortcuts.onKeyUp(for: .radialMenu) { [weak self] in MainActor.assumeIsolated { self?.release() } }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTap() }
        }
        apply(previous: nil)
    }

    func open() {
        guard settings.isEnabled, !settings.slices.isEmpty else { return NSSound.beep() }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let half = Self.panelSize / 2
        let wanted = settings.opensAtPointer ? mouse : CGPoint(x: visible.midX, y: visible.midY)
        center = CGPoint(x: min(max(wanted.x, visible.minX + half), visible.maxX - half), y: min(max(wanted.y, visible.minY + half), visible.maxY - half))
        tracker = RadialTracker(origin: mouse)
        lastMouse = mouse
        highlighted = nil
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
        isOpen = true
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: Self.trackInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.track() }
        }
        installKeyMonitor()
    }

    func close() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        isOpen = false
        highlighted = nil
    }

    func release() {
        guard isOpen else { return }
        switch settings.mode {
        case .press:
            return
        case .pressOrHold:
            if let highlighted { run(highlighted) }
        case .hold:
            if let highlighted { run(highlighted) } else { close() }
        }
    }

    func run(_ index: Int) {
        guard settings.slices.indices.contains(index) else { return }
        let action = settings.slices[index].action
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.actionDelay) { [weak self] in self?.perform(action) }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func actions() -> [CommandItem] {
        CommandSources.actions(context).filter { $0.kind == .action || $0.kind == .toggle }
    }

    private func perform(_ action: RadialSlice.Action) {
        switch action {
        case .command(let id):
            CommandSources.actions(context).first { $0.id == id }?.run(nil)
        case .app(let path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        case .folder(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        case .link(let text):
            if let url = URL(string: text) { NSWorkspace.shared.open(url) }
        case .media(let code):
            MediaKeys.post(code)
        }
    }

    private func track() {
        let mouse = NSEvent.mouseLocation
        guard mouse != lastMouse, var tracker else { return }
        lastMouse = mouse
        let next = tracker.highlight(at: mouse, center: center, count: settings.slices.count)
        self.tracker = tracker
        if tracker.hasMoved && next != highlighted { highlighted = next }
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let digit = PanelKeys.digitKeys[keyCode]
            let windowNumber = event.windowNumber
            let isHandled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen, self.panel?.windowNumber == windowNumber else { return false }
                let count = self.settings.slices.count
                switch keyCode {
                case PanelKeys.escapeKey: self.close()
                case PanelKeys.returnKey, PanelKeys.enterKey: if let highlighted = self.highlighted { self.run(highlighted) }
                case CommandBarKeys.leftKey, PanelKeys.upKey: self.highlighted = ((self.highlighted ?? 0) - 1 + count) % count
                case CommandBarKeys.rightKey, PanelKeys.downKey: self.highlighted = ((self.highlighted ?? -1) + 1) % count
                default:
                    guard let digit, digit <= count else { return false }
                    self.run(digit - 1)
                }
                return true
            }
            return isHandled ? nil : event
        }
    }

    private func apply(previous: RadialSettings?) {
        if previous?.isEnabled != settings.isEnabled {
            if settings.isEnabled { KeyboardShortcuts.enable([.radialMenu]) } else { KeyboardShortcuts.disable([.radialMenu]) }
            if !settings.isEnabled { close() }
        }
        applyTap()
    }

    private func applyTap() {
        let needsTap = settings.isEnabled && settings.mouseButton != nil && AXIsProcessTrusted()
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
        guard let button = settings.mouseButton, Int(event.getIntegerValueField(.mouseEventButtonNumber)) == button - 1 else { return pass }
        if type == .otherMouseDown {
            if isOpen { close() } else { open() }
        } else {
            release()
        }
        return nil
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

    var body: some View {
        let slices = controller.settings.slices
        ZStack {
            Color.clear.contentShape(Rectangle()).onTapGesture { controller.close() }
            Circle()
                .fill(.regularMaterial)
                .frame(width: RadialMenuController.discSize, height: RadialMenuController.discSize)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
                .onTapGesture { if let highlighted = controller.highlighted { controller.run(highlighted) } }
            if let highlighted = controller.highlighted {
                RadialWedge(index: highlighted, count: slices.count)
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.45), Color.accentColor.opacity(0.1)], startPoint: .center, endPoint: .top))
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
                .foregroundStyle(isHighlighted ? Color.accentColor : .primary)
                .scaleEffect(isHighlighted ? 1.14 : 1)
                .offset(x: offset.x, y: -offset.y)
                .onTapGesture { controller.run(index) }
            }
            Circle()
                .fill(.thinMaterial)
                .frame(width: RadialMenuController.hubSize, height: RadialMenuController.hubSize)
                .overlay(Image(systemName: "xmark").foregroundStyle(.secondary))
                .onTapGesture { controller.close() }
        }
        .frame(width: RadialMenuController.panelSize, height: RadialMenuController.panelSize)
        .animation(.easeOut(duration: 0.12), value: controller.highlighted)
    }
}
