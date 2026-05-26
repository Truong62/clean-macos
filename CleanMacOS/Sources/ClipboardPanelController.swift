import AppKit
import SwiftUI

/// A borderless-ish floating panel that is allowed to become the key window so
/// SwiftUI receives keyboard input immediately (no click required).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns the floating NSPanel for the global hotkey. On select it copies the
/// item, restores the previously-frontmost app, then synthesizes ⌘V.
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var previousApp: NSRunningApplication?
    private let clipboard: ClipboardViewModel

    init(clipboard: ClipboardViewModel) {
        self.clipboard = clipboard
        super.init()
    }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication

        let content = ClipboardPanelView(
            clipboard: clipboard,
            onSelect: { [weak self] item in self?.select(item) },
            onCancel: { [weak self] in self?.close() }
        )

        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        // Appear over other Spaces and full-screen apps (Spotlight-style overlay).
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentViewController = NSHostingController(rootView: content)
        p.delegate = self
        positionAtCursor(p)
        panel = p

        // A nonactivating panel can become key (and accept typing/arrows) without
        // activating the whole app — so it works over a full-screen app and grabs
        // focus immediately, no click needed.
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
    }

    /// Place the panel near the mouse cursor, clamped to the screen under it.
    private func positionAtCursor(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        // Top-left of the panel at the cursor (panel drops down-right, like a menu).
        var origin = NSPoint(x: mouse.x, y: mouse.y - size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        panel.setFrameOrigin(origin)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func select(_ item: ClipboardItem) {
        clipboard.copy(item)   // writes to NSPasteboard
        close()
        guard let app = previousApp else { return }
        app.activate()
        // Let the target app become frontmost before pasting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            PasteService.pasteToFrontmostApp() // no-op (copy-only) if not trusted
        }
    }

    // Clear our reference when the user closes the panel via its close button.
    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}
