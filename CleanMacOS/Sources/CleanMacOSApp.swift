import SwiftUI
import AppKit
import KeyboardShortcuts

/// Keeps the app alive after the main window is closed (like Safari/Mail), so the
/// clipboard monitor and the ⌘⇧V hotkey keep working in the background.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Re-open the main window when the user clicks the Dock icon with no windows open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainWindowController.show(sender)
        }
        return true
    }
}

@main
struct CleanMacOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = AppViewModel()
    @StateObject private var updater = UpdaterViewModel()
    @StateObject private var clipboard = ClipboardViewModel()
    @StateObject private var monitor = SystemMonitor()
    @StateObject private var jira = JiraViewModel()
    @AppStorage("showMenuBar") private var showMenuBar = true
    @State private var panelController: ClipboardPanelController?

    var body: some Scene {
        Window("Clean macOS", id: "main") {
            ContentView()
                .environmentObject(vm)
                .environmentObject(updater)
                .environmentObject(clipboard)
                .environmentObject(jira)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    setAppIcon()
                    monitor.startSampling(interval: 3)
                    clipboard.startMonitoring()
                    jira.restartBackgroundWork()
                    if panelController == nil {
                        let controller = ClipboardPanelController(clipboard: clipboard)
                        panelController = controller
                        KeyboardShortcuts.onKeyUp(for: .showClipboardHistory) {
                            controller.toggle()
                        }
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 750)
        .commands {
            // Disable New Window (Cmd+N)
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)

                Toggle("Automatically Check for Updates", isOn: updater.automaticallyChecksForUpdates)
            }

            CommandGroup(after: .toolbar) {
                Button("Scan") {
                    Task { await vm.scan() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView(monitor: monitor, jira: jira)
        } label: {
            Label(String(format: " %.0f%%", monitor.latestCPU), systemImage: "sparkles")
        }
        .menuBarExtraStyle(.window)
    }

    private func setAppIcon() {
        guard Bundle.main.bundleURL.pathExtension != "app",
              let url = Bundle._module.url(forResource: "icon_512x512@2x", withExtension: "png",
                                           subdirectory: "Assets.xcassets/AppIcon.appiconset"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }
}

#if canImport(Foundation)
// Make Bundle.module available for both SPM and Xcode builds
private extension Foundation.Bundle {
    static var _module: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }
}
#endif
