import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension Notification.Name {
    static let toggleClipboardPanel = Notification.Name("mackit.toggleClipboardPanel")
}

@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 560, height: 420)
    static let minimumHeight: CGFloat = 300
    static let previewWidth: CGFloat = 280
    static let pasteDelay: TimeInterval = 0.12
    static let copyOnlyApps: Set<String> = ["com.microsoft.rdc.macos", "com.microsoft.rdc.osx.beta"]

    private var panel: NSPanel?
    private var askedAccessibility = false
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var toggleObserver: NSObjectProtocol?
    private let clipboard: ClipboardViewModel
    private let model: ClipboardPanelModel

    init(clipboard: ClipboardViewModel) {
        self.clipboard = clipboard
        model = ClipboardPanelModel(clipboard: clipboard)
        super.init()
        model.onPaste = { [weak self] in self?.paste($0) }
        model.onCopy = { [weak self] in self?.copyOnly($0) }
        model.onClose = { [weak self] in self?.close() }
        model.onPreviewToggle = { [weak self] in self?.resizeForPreview($0) }
        toggleObserver = NotificationCenter.default.addObserver(forName: .toggleClipboardPanel, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
        }
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.activationPolicy == .regular && front?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? front : nil
        model.reset()
        let cards = model.layout == .cards
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let cardFrame = ClipboardCardGeometry.frame(in: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768))
        let width = Self.size.width + (model.showsPreview ? Self.previewWidth : 0)
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: Self.size.height),
                                 styleMask: cards ? [.borderless, .nonactivatingPanel] : [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = !cards
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if !cards { panel.minSize = NSSize(width: Self.size.width, height: Self.minimumHeight) }
        let host = NSHostingController(rootView: ClipboardPanelView(model: model, clipboard: clipboard).environmentObject(clipboard))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: width, height: Self.size.height))
        panel.delegate = self
        if cards { panel.setFrame(cardFrame, display: false) } else { positionAtCursor(panel) }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installKeyMonitor()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, !panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
                let appID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
                guard !appID.contains("AccessibilityKeyboard") else { return }
                self.close()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        removeKeyMonitor()
        let closing = panel
        panel = nil
        closing?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        panel = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func positionAtCursor(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    private func resizeForPreview(_ showsPreview: Bool) {
        guard let panel, model.layout != .cards else { return }
        var frame = panel.frame
        frame.size.width += showsPreview ? Self.previewWidth : -Self.previewWidth
        panel.setFrame(frame, display: true, animate: true)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let windowNumber = event.windowNumber
            let isHandled = MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.windowNumber == windowNumber else { return false }
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                if PanelKeys.isAppCommand(keyCode: keyCode, modifiers: modifiers) {
                    if keyCode == PanelKeys.closeKey { self.close() } else { NSSound.beep() }
                    return true
                }
                return self.model.handle(keyCode: keyCode, modifiers: modifiers)
            }
            return isHandled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func paste(_ items: [ClipboardItem]) {
        close()
        guard clipboard.copy(items) else { return }
        guard let app = previousApp, !Self.copyOnlyApps.contains(app.bundleIdentifier ?? "") else { return }
        guard PasteService.isAccessibilityTrusted else {
            if !askedAccessibility { askedAccessibility = true; PasteService.requestAccessibility() }
            else { NSSound.beep() }
            return
        }
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pasteDelay) {
            PasteService.pasteToFrontmostApp()
        }
    }

    private func copyOnly(_ items: [ClipboardItem]) {
        guard clipboard.copy(items) else { return }
        close()
    }
}
