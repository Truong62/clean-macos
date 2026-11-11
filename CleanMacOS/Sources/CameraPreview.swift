@preconcurrency import AVFoundation
import AppKit
import KeyboardShortcuts
import SwiftUI

struct CameraSettings: Codable, Equatable {
    var isEnabled = false
    var preferredCamera: String?
}

struct CameraOption: Identifiable, Equatable {
    let id: String
    let name: String
}

@MainActor
final class CameraPreviewController: NSObject, ObservableObject, NSWindowDelegate {
    enum Status: Equatable {
        case starting, running, denied, noCamera, unavailable
    }

    static let settingsKey = "cameraPreview.settings"
    static let size = NSSize(width: 320, height: 240)
    static let topInset: CGFloat = 48
    static let cornerRadius: CGFloat = 14
    static let promptGrace: TimeInterval = 1
    static let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
    static let privacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"

    @Published var settings: CameraSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if settings.isEnabled { KeyboardShortcuts.enable([.cameraPreview]) } else { KeyboardShortcuts.disable([.cameraPreview]) }
        }
    }
    @Published private(set) var status = Status.starting
    @Published private(set) var cameras: [CameraOption] = []
    @Published private(set) var current: String?

    let previewLayer = AVCaptureVideoPreviewLayer()
    private var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "mackit.camera-preview")
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var deviceObservers: [NSObjectProtocol] = []
    private var ignoresResignUntil = Date.distantPast

    override init() {
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(CameraSettings.self, from: $0) }
            ?? CameraSettings()
        super.init()
        previewLayer.videoGravity = .resizeAspectFill
        KeyboardShortcuts.onKeyUp(for: .cameraPreview) { [weak self] in MainActor.assumeIsolated { self?.toggle() } }
        if !settings.isEnabled { KeyboardShortcuts.disable([.cameraPreview]) }
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() {
        if isOpen { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        if let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.maxY - Self.topInset - Self.size.height))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installMonitors()
        start()
    }

    func hide() {
        removeMonitors()
        panel?.orderOut(nil)
        stopSession()
    }

    func select(_ id: String) {
        settings.preferredCamera = id
        current = id
        startSession()
    }

    func retry() {
        current = nil
        start()
    }

    func openPrivacySettings() {
        hide()
        if let url = URL(string: Self.privacySettingsURL) { NSWorkspace.shared.open(url) }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard Date() > ignoresResignUntil else { return }
        hide()
    }

    static func discover() -> [CameraOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified).devices
            .map { CameraOption(id: $0.uniqueID, name: $0.localizedName) }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            status = .starting
            ignoresResignUntil = .distantFuture
            AVCaptureDevice.requestAccess(for: .video) { [weak self] isGranted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.finishPermissionPrompt(isGranted: isGranted) }
                }
            }
        default:
            status = .denied
        }
    }

    private func finishPermissionPrompt(isGranted: Bool) {
        ignoresResignUntil = Date().addingTimeInterval(Self.promptGrace)
        guard isOpen else { return }
        panel?.makeKeyAndOrderFront(nil)
        if isGranted { startSession() } else { status = .denied }
    }

    private func startSession() {
        cameras = Self.discover()
        let preferred = settings.preferredCamera ?? AVCaptureDevice.systemPreferredCamera?.uniqueID
        current = CameraChoice.pick(available: cameras.map(\.id), preferred: preferred, current: current)
        stopSession()
        guard let current, let device = AVCaptureDevice(uniqueID: current) else {
            status = .noCamera
            return
        }
        status = .starting
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                status = .unavailable
                return
            }
            session.addInput(input)
        } catch {
            NSLog("CameraPreviewController.startSession failed for \(device.localizedName): \(error.localizedDescription)")
            status = .unavailable
            return
        }
        self.session = session
        previewLayer.session = session
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        sessionQueue.async { [weak self] in
            session.startRunning()
            let isRunning = session.isRunning
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.session === session else { return }
                    self.status = isRunning ? .running : .unavailable
                }
            }
        }
    }

    private func stopSession() {
        guard let session else { return }
        self.session = nil
        previewLayer.session = nil
        sessionQueue.async { session.stopRunning() }
    }

    private func devicesChanged() {
        guard isOpen, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        cameras = Self.discover()
        if current == nil || !cameras.contains(where: { $0.id == current }) {
            current = nil
            startSession()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: CameraPreviewView(controller: self))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(Self.size)
        panel.delegate = self
        return panel
    }

    private func installMonitors() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let windowNumber = event.windowNumber
            let isHandled = MainActor.assumeIsolated { () -> Bool in
                guard let self, keyCode == PanelKeys.escapeKey, self.panel?.windowNumber == windowNumber else { return false }
                self.hide()
                return true
            }
            return isHandled ? nil : event
        }
        deviceObservers = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devicesChanged() }
            }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        deviceObservers = []
    }
}

final class CameraLayerView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct CameraLayerHost: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> CameraLayerView {
        let view = CameraLayerView()
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: CameraLayerView, context: Context) {}
}

struct CameraPreviewView: View {
    @ObservedObject var controller: CameraPreviewController
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.black
            CameraLayerHost(layer: controller.previewLayer)
            message
        }
        .overlay(alignment: .topTrailing) {
            if isHovering, controller.cameras.count > 1 {
                Menu {
                    ForEach(controller.cameras) { camera in
                        Button { controller.select(camera.id) } label: {
                            if camera.id == controller.current { Label(camera.name, systemImage: "checkmark") } else { Text(camera.name) }
                        }
                    }
                } label: {
                    Image(systemName: "camera.rotate")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CameraPreviewController.cornerRadius))
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var message: some View {
        switch controller.status {
        case .starting:
            ProgressView().controlSize(.small).tint(.white)
        case .running:
            EmptyView()
        case .denied:
            VStack(spacing: 10) {
                Label("Camera access is off", systemImage: "video.slash.fill")
                Button("Open Settings") { controller.openPrivacySettings() }
            }
            .foregroundStyle(.white)
        case .noCamera:
            Label("No camera found", systemImage: "video.slash")
                .foregroundStyle(.white.opacity(0.8))
        case .unavailable:
            VStack(spacing: 10) {
                Label("The camera is unavailable", systemImage: "exclamationmark.triangle.fill")
                Button("Try Again") { controller.retry() }
            }
            .foregroundStyle(.white)
        }
    }
}
