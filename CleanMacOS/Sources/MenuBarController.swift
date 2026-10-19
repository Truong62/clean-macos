import AppKit

@MainActor
enum MainWindowController {
    static let title = "Clean macOS"

    static func show() {
        show(NSApp)
    }

    static func show(_ application: NSApplication) {
        guard let window = mainWindow(in: application) else { return }
        bringToActiveSpace(window)
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    static func bringToActiveSpace(_ window: NSWindow) {
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenAuxiliary])
    }

    private static func mainWindow(in application: NSApplication) -> NSWindow? {
        application.windows.first { $0.title == title && $0.canBecomeMain }
    }
}
