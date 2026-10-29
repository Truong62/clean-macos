import AppKit
import ScreenCaptureKit

enum WindowFrames {
    static let tolerance: CGFloat = 4

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

extension AgentRecordingSession {
    static let overlaySettle: Duration = .milliseconds(250)

    func inPlaceTarget(_ arguments: StartRecordingArguments) async throws -> RecordingTarget {
        try DemoInput.ensureTrusted()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let window = try pickWindow(arguments, from: Self.recordableWindows(content))
        guard let pid = window.owningApplication?.processID else { throw MCPToolError.message("That window has no app.") }
        let isOnScreen = BackgroundInput.windows(of: pid).compactMap(AccessibilityFinder.frame).contains { WindowFrames.matches($0, window.frame) }
        guard isOnScreen else {
            throw MCPToolError.message("That window is minimized or in the Stage Manager strip. Leave it on a screen (other windows may cover it), or use background: false.")
        }
        guard let display = content.displays.max(by: {
            $0.frame.intersection(window.frame).width * $0.frame.intersection(window.frame).height
                < $1.frame.intersection(window.frame).width * $1.frame.intersection(window.frame).height
        }) else { throw MCPToolError.message("No display found.") }
        overlay.show(showsClicks: false, only: display.frame)
        try await Task.sleep(for: Self.overlaySettle)
        let refreshed = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let apps = refreshed.applications.filter { $0.processID == pid || $0.processID == getpid() }
        return RecordingTarget(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []),
                               sourceRect: RecordingSources.region(of: window.frame, on: display.frame), display: display.frame,
                               description: "window \"\(window.title ?? "")\" of \(window.owningApplication?.applicationName ?? "an app"), recorded in place",
                               processID: pid)
    }

    private func pickWindow(_ arguments: StartRecordingArguments, from windows: [SCWindow]) throws -> SCWindow {
        if let id = arguments.windowID {
            guard let window = windows.first(where: { Int($0.windowID) == id }) else {
                throw MCPToolError.message("No on-screen window has id \(id). Call list_sources.")
            }
            return window
        }
        if let query = arguments.window {
            let sources = windows.map { SourceWindow(id: Int($0.windowID), app: $0.owningApplication?.applicationName ?? "",
                                                     bundleID: $0.owningApplication?.bundleIdentifier ?? "", title: $0.title ?? "",
                                                     area: $0.frame.width * $0.frame.height) }
            guard let match = RecordingSources.bestWindow(matching: query, in: sources),
                  let window = windows.first(where: { Int($0.windowID) == match.id }) else {
                throw MCPToolError.message("No on-screen window matches \"\(query)\". Call list_sources.")
            }
            return window
        }
        if let query = arguments.app {
            let owned = windows.filter {
                RecordingSources.matchesApp(query, name: $0.owningApplication?.applicationName ?? "", bundleID: $0.owningApplication?.bundleIdentifier ?? "")
            }
            guard let window = owned.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw MCPToolError.message("No on-screen window of an app matching \"\(query)\". Call list_sources.")
            }
            return window
        }
        throw MCPToolError.message("Background recording needs a url (hidden browser) or a window or app (recorded in place). Pass background: false to record a whole display.")
    }
}
