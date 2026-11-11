import AppKit
import AVFoundation
import Combine
import KeyboardShortcuts
import ScreenCaptureKit
import SwiftUI

@MainActor
final class RecordingStudio: ObservableObject {
    static let settingsKey = "recording.studio.settings"
    @Published var settings: RecorderSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if settings.shortcut { KeyboardShortcuts.enable(.recordScreen) } else { KeyboardShortcuts.disable(.recordScreen) }
        }
    }
    @Published private(set) var pending = false
    @Published private(set) var paused = false
    @Published private(set) var elapsed = 0.0
    @Published var message: String?
    let recorder: ScreenRecorder
    weak var capture: ScreenshotController?
    var openEditor: ((URL, VideoTracks) -> Void)?
    var saved: ((URL) -> Void)?
    private var countdown: Task<Void, Never>?
    private var timer: Timer?
    private var panel: NSPanel?
    private var outline: NSPanel?
    private let hud = InputHUD()
    private var activity: NSObjectProtocol?
    private var folder: URL?
    private var tracks = VideoTracks()
    private var cursor = RecordingCursorReader()
    private var monitors: [Any] = []
    private var pointerTimer: DispatchSourceTimer?
    private var lowDisk = false
    private var observation: AnyCancellable?

    var active: Bool { pending || recorder.isRecording }
    var title: String { recorder.isRecording ? "Stop Recording" : pending ? "Cancel Recording" : "Record Screen" }
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacKit/VideoTakes", isDirectory: true)
    }
    var saveFolder: URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        guard !settings.folder.isEmpty else { return desktop }
        let candidate = URL(fileURLWithPath: settings.folder, isDirectory: true)
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory) && directory.boolValue ? candidate : desktop
    }

    init(recorder: ScreenRecorder) {
        self.recorder = recorder
        VideoTakeFiles.sweep(Self.root, now: Date())
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(RecorderSettings.self, from: $0) } ?? RecorderSettings()
        KeyboardShortcuts.onKeyUp(for: .recordScreen) { [weak self] in MainActor.assumeIsolated { self?.trigger() } }
        if settings.shortcut { KeyboardShortcuts.enable(.recordScreen) } else { KeyboardShortcuts.disable(.recordScreen) }
        recorder.didFinishMaster = { [weak self] url in self?.finished(url) }
        observation = recorder.$phase.sink { [weak self] phase in
            Task { @MainActor in
                if phase == .idle, self?.folder != nil, self?.recorder.message != nil { self?.teardown() }
            }
        }
    }

    func trigger() {
        if pending {
            countdown?.cancel()
            capture?.cancel()
            pending = false
            Task { await recorder.stop() }
            teardown()
            return
        }
        if recorder.isRecording { Task { await recorder.stop() }; return }
        guard recorder.phase == .idle else { return }
        guard Self.freeBytes(at: saveFolder) >= 2_000_000_000 else { notify("At least 2 GB of free space is needed to record."); return }
        message = nil
        pending = true
        capture?.start(.recording)
        if capture?.busy != true { pending = false }
    }

    func selectionCancelled() { pending = false }

    func select(_ rect: CGRect, shot: CaptureDisplay, window: CaptureWindow?) {
        guard recorder.phase == .idle else { return }
        guard let region = RecordingRegion.fit(rect, in: CGRect(origin: .zero, size: shot.frame.size), scale: shot.scale) else {
            pending = false
            notify("Choose an area at least 32 pixels wide and high.")
            return
        }
        guard Self.freeBytes(at: saveFolder) >= 2_000_000_000 else { pending = false; notify("At least 2 GB of free space is needed to record."); return }
        pending = true
        countdown = Task {
            do {
                var microphone = settings.microphone
                if microphone, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                    microphone = false
                    notify("Microphone access denied. Recording continues without it.")
                }
                if settings.typing, !AXIsProcessTrusted() {
                    PasteService.requestAccessibility()
                    notify("Allow Accessibility to capture typing times. No keys are stored.")
                }
                try Task.checkCancellation()
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == shot.id }) else { throw RecordingError.failed("The display was disconnected.") }
                let filter: SCContentFilter
                let source: CGRect?
                if let window {
                    guard let target = content.windows.first(where: { $0.windowID == window.id }) else { throw RecordingError.failed("The selected window closed.") }
                    filter = SCContentFilter(desktopIndependentWindow: target)
                    source = nil
                } else {
                    let own = content.applications.filter { $0.processID == getpid() }
                    let ordinary = content.windows.filter { window in window.owningApplication?.processID == getpid() && window.windowLayer == 0 && NSApp.windows.contains(where: { local in local.windowNumber == Int(window.windowID) && local.sharingType != .none }) }
                    filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: ordinary)
                    source = region
                }
                let folder = try VideoTakeFiles.create(in: Self.root)
                self.folder = folder
                let options = RecordingOptions(systemAudio: settings.systemAudio, microphone: microphone,
                                               framesPerSecond: settings.framesPerSecond == 30 ? 30 : 60,
                                               folder: saveFolder, masterURL: folder.appendingPathComponent("master.mov"), audioProcessID: window?.owner)
                await recorder.startPreview(filter, options: options, sourceRect: source, showsCursor: false)
                guard recorder.phase == .previewing else { throw RecordingError.failed(recorder.message ?? "Recording could not start.") }
                for number in (0..<max(0, min(10, settings.countdown))).reversed() {
                    hud.show("\(number + 1)", for: 1)
                    try await Task.sleep(for: .seconds(1))
                }
                try Task.checkCancellation()
                recorder.startRecording()
                pending = false
                paused = false
                elapsed = 0
                lowDisk = false
                tracks = VideoTracks()
                tracks.displayScale = Double(shot.scale)
                cursor = RecordingCursorReader()
                activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Screen recording")
                showPill(on: shot)
                if window == nil { showOutline(region, shot: shot) }
                startTracks(rect: window?.frame ?? region.offsetBy(dx: display.frame.minX, dy: display.frame.minY), windowID: window?.id)
                timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
                if let timer { RunLoop.main.add(timer, forMode: .common) }
            } catch {
                pending = false
                await recorder.stop()
                teardown()
                if !(error is CancellationError) { notify(error.localizedDescription) }
            }
        }
    }

    func togglePause() {
        guard recorder.isRecording else { return }
        if let time = recorder.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock())) { elapsed = time }
        paused.toggle()
        if paused { recorder.pauseCapture() } else { recorder.resumeCapture() }
    }

    private func tick() {
        recorder.refreshAudioTap()
        if let time = recorder.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock())) { elapsed = time }
        if let folder, Self.freeBytes(at: folder) < 500_000_000, recorder.isRecording {
            lowDisk = true
            notify("Storage is nearly full. Saving the recording.")
            Task { await recorder.stop() }
        }
    }

    private func startTracks(rect: CGRect, windowID: CGWindowID?) {
        guard settings.pointer || settings.typing else { return }
        if settings.pointer {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "mackit.pointer", qos: .userInteractive))
            timer.schedule(deadline: .now(), repeating: .milliseconds(8))
            timer.setEventHandler { [weak self] in
                let point = CGEvent(source: nil)?.location
                var currentRect = rect
                if let windowID, let row = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
                   let bounds = row[kCGWindowBounds as String] as? [String: Any], let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 0, frame.height > 0 { currentRect = frame }
                let recordedRect = currentRect
                let host = CMClockGetTime(CMClockGetHostTimeClock())
                let held = CGEventSource.buttonState(.combinedSessionState, button: .left) || CGEventSource.buttonState(.combinedSessionState, button: .right)
                Task { @MainActor in
                    guard let self, let point, let time = self.recorder.elapsed(at: host) else { return }
                    let cursor = self.cursor.read()
                    if let id = cursor.identity, let shape = cursor.shape { self.tracks.cursors[id] = shape }
                    self.tracks.pointer.append(VideoPointerSample(time: time, point: CGPoint(x: (point.x - recordedRect.minX) / recordedRect.width, y: (point.y - recordedRect.minY) / recordedRect.height), visible: recordedRect.contains(point), pressed: held, shape: cursor.identity, scale: cursor.scale))
                }
            }
            timer.resume()
            pointerTimer = timer
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let time = self.recorder.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock())) else { return }
                    self.tracks.clicks.append(time)
                }
            }) { monitors.append(monitor) }
        }
        if settings.typing, AXIsProcessTrusted(), let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard !event.isARepeat else { return }
            MainActor.assumeIsolated {
                guard let self, let time = self.recorder.elapsed(at: CMClockGetTime(CMClockGetHostTimeClock())) else { return }
                self.tracks.typing.append(time)
            }
        }) { monitors.append(monitor) }
    }

    private func finished(_ url: URL) {
        teardown()
        try? JSONEncoder().encode(tracks).write(to: url.deletingLastPathComponent().appendingPathComponent("tracks.json"), options: .atomic)
        if settings.opensEditor && !lowDisk { openEditor?(url, tracks); folder = nil; return }
        let name = (ScreenRecording.fileName(at: Date()) as NSString).deletingPathExtension + ".mov"
        let destination = VideoTakeFiles.unique(saveFolder.appendingPathComponent(name))
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            saved?(destination)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } catch {
            notify("Could not save the master. Opening the editor to keep your take.")
            openEditor?(url, tracks)
        }
        folder = nil
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        pointerTimer?.cancel(); pointerTimer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        panel?.orderOut(nil); panel = nil
        outline?.orderOut(nil); outline = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func notify(_ text: String) { message = text; hud.show(text, for: 2) }

    private static func freeBytes(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }

    private func showPill(on shot: CaptureDisplay) {
        let screen = NSScreen.screens.first { $0.displayID == shot.id }
        let panel = NSPanel(contentRect: CGRect(x: shot.frame.midX - 75, y: (screen?.visibleFrame.maxY ?? shot.frame.maxY) - 42, width: 150, height: 32), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: RecordingPill(studio: self))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func showOutline(_ rect: CGRect, shot: CaptureDisplay) {
        let panel = NSPanel(contentRect: shot.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = CaptureScrollOutline(frame: CGRect(origin: .zero, size: shot.frame.size), area: rect)
        panel.orderFrontRegardless()
        outline = panel
    }
}

private struct RecordingPill: View {
    @ObservedObject var studio: RecordingStudio
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(studio.paused ? .gray : .red).frame(width: 7, height: 7)
                .phaseAnimator([false, true]) { view, phase in view.opacity(studio.paused ? 0.4 : phase ? 1 : 0.45) } animation: { _ in .easeInOut(duration: 0.7) }
            Text(ScreenRecording.elapsed(studio.elapsed)).font(.caption.monospacedDigit())
            Button { studio.togglePause() } label: { Image(systemName: studio.paused ? "play.fill" : "pause.fill") }.help(studio.paused ? "Resume" : "Pause")
            Button { studio.trigger() } label: { Image(systemName: "stop.fill") }.help("Stop")
        }
        .buttonStyle(.plain).padding(8).frame(width: 150, height: 32)
        .background(.ultraThinMaterial, in: Capsule()).environment(\.colorScheme, .dark)
    }
}
