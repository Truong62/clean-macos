import AppKit
import SwiftUI

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

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.contentViewController = NSHostingController(rootView: content)
        p.delegate = self
        p.center()
        panel = p

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
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
