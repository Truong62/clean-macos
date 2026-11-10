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
    private var previousApp: NSRunningApplication?
    private var keyMonitor: Any?
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
        previousApp = NSWorkspace.shared.frontmostApplication
        model.reset()
        let width = Self.size.width + (model.showsPreview ? Self.previewWidth : 0)
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: Self.size.height),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: Self.size.width, height: Self.minimumHeight)
        let host = NSHostingController(rootView: ClipboardPanelView(model: model, clipboard: clipboard).environmentObject(clipboard))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(NSSize(width: width, height: Self.size.height))
        panel.delegate = self
        positionAtCursor(panel)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installKeyMonitor()
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
        guard let panel else { return }
        var frame = panel.frame
        frame.size.width += showsPreview ? Self.previewWidth : -Self.previewWidth
        panel.setFrame(frame, display: true, animate: true)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, event.window === panel else { return event }
                if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                return self.model.handle(keyCode: event.keyCode, modifiers: event.modifierFlags) ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func paste(_ items: [ClipboardItem]) {
        guard clipboard.copy(items) else { return }
        close()
        guard let app = previousApp, !Self.copyOnlyApps.contains(app.bundleIdentifier ?? "") else { return }
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
