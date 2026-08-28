import AppKit

@MainActor
enum MainWindowController {
    static func show() {
        show(NSApp)
    }

    static func show(_ application: NSApplication) {
        guard let window = mainWindow(in: application) else { return }
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        application.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static func mainWindow(in application: NSApplication) -> NSWindow? {
        application.windows.first { $0.title == "Clean macOS" && $0.canBecomeMain }
    }
}
