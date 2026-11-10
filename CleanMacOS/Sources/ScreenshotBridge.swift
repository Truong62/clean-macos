import AppKit

@MainActor
enum ScreenshotEditorBridge {
    static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
}
