import AppKit
import Darwin

enum MCPReopenDecision {
    static func shouldLaunchMain(processArguments: [[String]]) -> Bool {
        processArguments.allSatisfy { $0.contains("--mcp") }
    }
}

@MainActor
final class MCPApplicationDelegate: NSObject, NSApplicationDelegate {
    static let reopenNotification = Notification.Name("click.ngoctruong.CleanMacOS.reopenMainWindow")
    static let showMainWindowArgument = "--show-main-window"
    private var launchPending = false

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        defer {
            sender.setActivationPolicy(.accessory)
            DispatchQueue.main.async { sender.setActivationPolicy(.accessory) }
        }
        guard !launchPending, let bundleID = Bundle.main.bundleIdentifier else { return false }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanMacOS", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let descriptor = open(directory.appendingPathComponent("mcp-reopen.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        let arguments = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
            .map { HeadlessBrowserFiles.arguments(of: $0.processIdentifier) }
        guard MCPReopenDecision.shouldLaunchMain(processArguments: arguments) else {
            close(descriptor)
            DistributedNotificationCenter.default().postNotificationName(Self.reopenNotification, object: nil,
                                                                         deliverImmediately: true)
            return false
        }
        launchPending = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [Self.showMainWindowArgument]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, _ in
            close(descriptor)
            Task { @MainActor in
                self?.launchPending = false
                sender.setActivationPolicy(.accessory)
            }
        }
        return false
    }
}
