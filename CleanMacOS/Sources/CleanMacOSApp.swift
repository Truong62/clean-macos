import SwiftUI
import AppKit
import KeyboardShortcuts

/// Keeps the app alive after the main window is closed (like Safari/Mail), so the
/// clipboard monitor and the ⌘⇧V hotkey keep working in the background.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyDataCleanup.removeJiraData()
        StartupRoutine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioHardware.restoreChangedDevices()
        HyperKeyMapping.restoreIfNeeded()
        PictureDimmer.restoreAll()
    }

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
enum AppEntry {
    static func main() {
        if CommandLine.arguments.contains(RecordingMCPServer.flag) {
            RecordingMCPServer.run()
        }
        CleanMacOSApp.main()
    }
}

struct CleanMacOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = AppViewModel()
    @StateObject private var updater = UpdaterViewModel()
    @StateObject private var clipboard: ClipboardViewModel
    @StateObject private var snippets: SnippetExpander
    @StateObject private var monitor: SystemMonitor
    @StateObject private var recordingStudio: RecordingStudio
    @StateObject private var videoEditors: VideoEditors
    @StateObject private var recorder: ScreenRecorder
    @StateObject private var agentRecording = AgentRecordingIndicator()
    @StateObject private var account = AccountViewModel()
    @StateObject private var library: MusicLibrary
    @StateObject private var music: MusicPlayer
    @StateObject private var keyboard: VietnameseKeyboard
    @StateObject private var keepAwake: KeepAwake
    @StateObject private var bluetooth = BluetoothSleepGuard()
    @StateObject private var windows: WindowManager
    @StateObject private var input = InputController()
    @StateObject private var finder = FinderTools()
    @StateObject private var diskImages = DiskImageWatcher()
    @StateObject private var shelf: ShelfController
    @StateObject private var brightness: BrightnessController
    @StateObject private var commandBar: CommandBarController
    @StateObject private var screenshotEditor: ScreenshotEditorController
    @StateObject private var screenshot: ScreenshotController
    @StateObject private var screenTools: ScreenTools
    @StateObject private var scratchpad: ScratchpadController
    @StateObject private var camera: CameraPreviewController
    @StateObject private var quitApps: QuitAppsController
    @StateObject private var radial: RadialMenuController
    @StateObject private var quickPanel: QuickPanelController
    @StateObject private var sound: SoundController
    @StateObject private var mixer: MixerController
    @StateObject private var homebrew: HomebrewController
    @StateObject private var appUpdates: AppUpdatesController
    @StateObject private var mediaTools = MediaToolsController()
    @StateObject private var aiUsage: AIUsageMonitor
    @StateObject private var island: IslandController
    @AppStorage("showMenuBar") private var showMenuBar = true
    @State private var panelController: ClipboardPanelController?

    init() {
        let clipboard = ClipboardViewModel()
        _clipboard = StateObject(wrappedValue: clipboard)
        let snippets = SnippetExpander(clipboard: clipboard)
        _snippets = StateObject(wrappedValue: snippets)
        let sound = SoundController()
        _sound = StateObject(wrappedValue: sound)
        let mixer = MixerController(sound: sound)
        _mixer = StateObject(wrappedValue: mixer)
        let monitor = SystemMonitor(store: .standard)
        _monitor = StateObject(wrappedValue: monitor)
        let library = MusicLibrary(legacyRoot: MusicLibrary.legacyRoot)
        _library = StateObject(wrappedValue: library)
        let music = MusicPlayer(library: library)
        _music = StateObject(wrappedValue: music)
        let aiUsage = AIUsageMonitor()
        _aiUsage = StateObject(wrappedValue: aiUsage)
        let keyboard = VietnameseKeyboard()
        _keyboard = StateObject(wrappedValue: keyboard)
        let keepAwake = KeepAwake()
        _keepAwake = StateObject(wrappedValue: keepAwake)
        let shelf = ShelfController()
        _shelf = StateObject(wrappedValue: shelf)
        let screenshotEditor = ScreenshotEditorController(shelf: shelf)
        _screenshotEditor = StateObject(wrappedValue: screenshotEditor)
        ScreenshotEditorBridge.open = { screenshotEditor.open($0) }
        let brightness = BrightnessController()
        _brightness = StateObject(wrappedValue: brightness)
        let screenTools = ScreenTools()
        _screenTools = StateObject(wrappedValue: screenTools)
        let recorder = ScreenRecorder()
        _recorder = StateObject(wrappedValue: recorder)
        let screenshot = ScreenshotController(screenTools: screenTools, shelf: shelf, recorder: recorder)
        let recordingStudio = RecordingStudio(recorder: recorder)
        _recordingStudio = StateObject(wrappedValue: recordingStudio)
        let videoEditors = VideoEditors(studio: recordingStudio)
        _videoEditors = StateObject(wrappedValue: videoEditors)
        recordingStudio.capture = screenshot
        screenshot.recordingStudio = recordingStudio
        recordingStudio.openEditor = { [weak videoEditors] url, tracks in Task { await videoEditors?.open(url, tracks: tracks) } }
        recordingStudio.saved = { [weak screenshot] url in Task { await screenshot?.rememberRecording(url) } }
        screenTools.screenshot = screenshot
        _screenshot = StateObject(wrappedValue: screenshot)
        let scratchpad = ScratchpadController()
        _scratchpad = StateObject(wrappedValue: scratchpad)
        let camera = CameraPreviewController()
        _camera = StateObject(wrappedValue: camera)
        let quitApps = QuitAppsController()
        _quitApps = StateObject(wrappedValue: quitApps)
        let windows = WindowManager()
        _windows = StateObject(wrappedValue: windows)
        let homebrew = HomebrewController()
        _homebrew = StateObject(wrappedValue: homebrew)
        _appUpdates = StateObject(wrappedValue: AppUpdatesController(homebrew: homebrew))
        let context = CommandContext(keepAwake: keepAwake, sound: sound, brightness: brightness, clipboard: clipboard, snippets: snippets, shelf: shelf,
                                     screenTools: screenTools, scratchpad: scratchpad, camera: camera, quitApps: quitApps) { page in
            MainWindowController.show()
            NotificationCenter.default.post(name: .openSidebarPage, object: page)
        }
        _island = StateObject(wrappedValue: IslandController(context: context, music: music, agents: aiUsage, mixer: mixer, monitor: monitor))
        _commandBar = StateObject(wrappedValue: CommandBarController(context: context))
        _radial = StateObject(wrappedValue: RadialMenuController(context: context, windows: windows))
        _quickPanel = StateObject(wrappedValue: QuickPanelController(context: context))
        KeyboardShortcuts.onKeyUp(for: .toggleKeepAwake) {
            MainActor.assumeIsolated { keepAwake.toggle() }
        }
        KeyboardShortcuts.onKeyUp(for: .toggleVietnamese) {
            MainActor.assumeIsolated { keyboard.toggleMode() }
        }
    }

    var body: some Scene {
        Window(MainWindowController.title, id: "main") {
            ContentView()
                .environmentObject(vm)
                .environmentObject(updater)
                .environmentObject(clipboard)
                .environmentObject(recorder)
                .environmentObject(recordingStudio)
                .environmentObject(videoEditors)
                .environmentObject(account)
                .environmentObject(library)
                .environmentObject(music)
                .environmentObject(keyboard)
                .environmentObject(keepAwake)
                .environmentObject(bluetooth)
                .environmentObject(windows)
                .environmentObject(input)
                .environmentObject(snippets)
                .environmentObject(finder)
                .environmentObject(diskImages)
                .environmentObject(shelf)
                .environmentObject(brightness)
                .environmentObject(sound)
                .environmentObject(mixer)
                .environmentObject(commandBar)
                .environmentObject(radial)
                .environmentObject(quickPanel)
                .environmentObject(screenTools)
                .environmentObject(screenshotEditor)
                .environmentObject(screenshot)
                .environmentObject(scratchpad)
                .environmentObject(camera)
                .environmentObject(quitApps)
                .environmentObject(aiUsage)
                .environmentObject(monitor)
                .environmentObject(homebrew)
                .environmentObject(appUpdates)
                .environmentObject(mediaTools)
                .environmentObject(island)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    Task { await account.refreshSession() }
                    setAppIcon()
                    monitor.startSampling(interval: 3)
                    clipboard.startMonitoring()
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
            MenuBarView(studio: recordingStudio, monitor: monitor, recorder: recorder, agentRecording: agentRecording, music: music, keepAwake: keepAwake, clipboard: clipboard, shelf: shelf, screenshot: screenshot, brightness: brightness)
                .environmentObject(island)
        } label: {
            Label(monitor.showsCPUReadout ? "" : String(format: " %.0f%%", monitor.latestCPU), systemImage: recorder.isRecording || agentRecording.isRecording ? "record.circle.fill" : keepAwake.isActive ? "cup.and.saucer.fill" : "square.grid.2x2.fill")
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra(isInserted: Binding(get: { monitor.showsReadouts }, set: { isInserted in if !isInserted { monitor.settings.readouts = [] } })) {
            MonitorMenu(monitor: monitor)
        } label: {
            Image(nsImage: monitor.readoutImage)
        }
        .menuBarExtraStyle(.menu)

        MenuBarExtra(isInserted: Binding(get: { keyboard.preferences.isEnabled }, set: { value in keyboard.update { $0.isEnabled = value } })) {
            TypingMenu(keyboard: keyboard)
        } label: {
            Image(nsImage: TypingBadge.image(keyboard.isVietnamese ? "V" : "E"))
        }
        .menuBarExtraStyle(.menu)

        MenuBarExtra(isInserted: Binding(get: { sound.settings.showsMicBadge && sound.isMicMuted },
                                         set: { isInserted in if !isInserted && sound.isMicMuted { sound.settings.showsMicBadge = false } })) {
            MicBadgeMenu(sound: sound)
        } label: {
            Image(nsImage: MicBadge.image)
        }
        .menuBarExtraStyle(.menu)

        MenuBarExtra(isInserted: Binding(get: { clipboard.options.showsLatestInMenuBar && clipboard.latestItem != nil },
                                         set: { isInserted in
                                             if !isInserted && clipboard.latestItem != nil { clipboard.options.showsLatestInMenuBar = false }
                                         })) {
            ClipboardMenu(clipboard: clipboard)
        } label: {
            Text(clipboard.latestItem?.menuTitle(length: clipboard.options.latestLength) ?? "")
        }
        .menuBarExtraStyle(.menu)
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
