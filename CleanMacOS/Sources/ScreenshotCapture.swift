import AppKit
import Carbon
import Combine
import AVFoundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import KeyboardShortcuts
import SwiftUI

struct CaptureDisplay {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let image: CGImage
}

@MainActor
enum ScreenshotHardware {
    static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    @MainActor
    struct Prepared {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let id: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
        func capture() async throws -> CaptureDisplay {
            guard ScreenshotHardware.permitted else { throw CaptureError.permission }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return CaptureDisplay(id: id, frame: frame, scale: scale, image: image)
        }
    }

    static func prepare(_ screen: NSScreen, settings: ScreenshotSettings) async throws -> Prepared {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.unavailable }
        let own = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let excluded = settings.hideOwnWindows ? own : own.filter { $0.windowLayer != 0 }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
        configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
        configuration.showsCursor = settings.includePointer
        configuration.colorSpaceName = CGColorSpace.sRGB
        return Prepared(filter: SCContentFilter(display: display, excludingWindows: excluded), configuration: configuration,
                        id: display.displayID, frame: screen.frame, scale: screen.backingScaleFactor)
    }

    static func display(_ screen: NSScreen, settings: ScreenshotSettings) async throws -> CaptureDisplay {
        let prepared = try await prepare(screen, settings: settings)
        return try await prepared.capture()
    }

    static func window(_ id: CGWindowID, scale: CGFloat) async throws -> CGImage {
        guard permitted else { throw CaptureError.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.unavailable }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.ignoreShadowsSingleWindow = true
        let base: CGImage
        if let buffered = WindowBufferCapture.image(id: id, frame: window.frame, scale: scale) { base = buffered }
        else { base = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) }
        let listed = windows()
        guard let parent = listed.first(where: { $0.id == id }) else { return base }
        var standardIDs = Set<UInt32>()
        if AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(parent.owner)
            let elements: [AXUIElement] = AXWindow.value(app, kAXWindowsAttribute) ?? []
            for element in elements {
                guard let subrole: String = AXWindow.value(element, kAXSubroleAttribute), subrole == kAXStandardWindowSubrole,
                      let position: AXValue = AXWindow.value(element, kAXPositionAttribute), let size: AXValue = AXWindow.value(element, kAXSizeAttribute) else { continue }
                var point = CGPoint.zero
                var dimensions = CGSize.zero
                guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { continue }
                let frame = CGRect(origin: point, size: dimensions)
                for item in listed where item.owner == parent.owner && item.frame == frame { standardIDs.insert(item.id) }
            }
        }
        let sheets = CaptureWindows.sheets(for: parent, windows: listed, standardIDs: standardIDs)
        guard !sheets.isEmpty, let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for sheet in sheets {
            guard let window = content.windows.first(where: { $0.windowID == sheet.id }) else { continue }
            configuration.width = Int(sheet.frame.width * scale)
            configuration.height = Int(sheet.frame.height * scale)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration) else { continue }
            let rect = CGRect(x: (sheet.frame.minX - parent.frame.minX) * scale, y: (parent.frame.maxY - sheet.frame.maxY) * scale,
                              width: sheet.frame.width * scale, height: sheet.frame.height * scale)
            context.draw(image, in: rect)
        }
        return context.makeImage() ?? base
    }

    static func windows() -> [CaptureWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { row in
            guard let id = row[kCGWindowNumber as String] as? UInt32,
                  let owner = row[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return CaptureWindow(id: id, owner: owner, title: row[kCGWindowName as String] as? String ?? "", frame: frame,
                                 layer: row[kCGWindowLayer as String] as? Int ?? 0, alpha: row[kCGWindowAlpha as String] as? Double ?? 1)
        }
    }

    enum CaptureError: Error { case unavailable, permission, encoding }
}

enum CaptureImages {
    static func png(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        var encoded = image
        if image.colorSpace?.name != CGColorSpace.sRGB,
           let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            encoded = context.makeImage() ?? image
        }
        CGImageDestinationAddImage(destination, encoded, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func resized(_ image: CGImage, factor: CGFloat) -> CGImage {
        guard factor > 0, factor != 1,
              let context = CGContext(data: nil, width: max(1, Int(CGFloat(image.width) * factor)), height: max(1, Int(CGFloat(image.height) * factor)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage() ?? image
    }

    static func gray(_ image: CGImage) -> GrayFrame {
        let width = min(256, image.width)
        var pixels = [UInt8](repeating: 0, count: width * image.height)
        pixels.withUnsafeMutableBytes { bytes in
            if let context = CGContext(data: bytes.baseAddress, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                context.translateBy(x: 0, y: CGFloat(image.height))
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
            }
        }
        return GrayFrame(width: width, height: image.height, pixels: pixels)
    }

    static func trimTransparent(_ image: CGImage) -> CGImage {
        func hasPixels(_ rect: CGRect) -> Bool {
            guard let strip = image.cropping(to: rect) else { return false }
            var bytes = [UInt8](repeating: 0, count: strip.width * strip.height * 4)
            let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: strip.width, height: strip.height, bitsPerComponent: 8,
                                              bytesPerRow: strip.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(strip, in: CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
                return true
            }
            return rendered && stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 0 }
        }
        var top = 0
        var bottom = image.height
        var left = 0
        var right = image.width
        while top < bottom && !hasPixels(CGRect(x: 0, y: top, width: image.width, height: 1)) { top += 1 }
        guard top < bottom else { return image }
        while bottom > top && !hasPixels(CGRect(x: 0, y: bottom - 1, width: image.width, height: 1)) { bottom -= 1 }
        while left < right && !hasPixels(CGRect(x: left, y: top, width: 1, height: bottom - top)) { left += 1 }
        while right > left && !hasPixels(CGRect(x: right - 1, y: top, width: 1, height: bottom - top)) { right -= 1 }
        return image.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) ?? image
    }

    static func append(_ base: CGImage, frame: CGImage, rows: Int, footer: Int) -> CGImage? {
        let height = base.height + rows
        guard rows > 0, rows + footer <= frame.height, height * base.width <= 60_000_000,
              let strip = frame.cropping(to: CGRect(x: 0, y: frame.height - rows - footer, width: frame.width, height: rows)),
              let context = CGContext(data: nil, width: base.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: rows, width: base.width, height: base.height))
        context.draw(strip, in: CGRect(x: 0, y: footer, width: base.width, height: rows))
        if footer > 0, let bottom = frame.cropping(to: CGRect(x: 0, y: frame.height - footer, width: frame.width, height: footer)) {
            context.draw(bottom, in: CGRect(x: 0, y: 0, width: base.width, height: footer))
        }
        return context.makeImage()
    }
}

@MainActor
final class ScreenshotController: ObservableObject {
    static let settingsKey = "screenshot.settings"
    @Published var settings: ScreenshotSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            applyShortcuts()
        }
    }
    @Published private(set) var history: [CaptureHistoryEntry] = []
    @Published private(set) var busy = false
    @Published var status = ""
    @Published var scrollHeight = 0
    @Published private(set) var links: [CaptureLink] = []
    @Published private(set) var uploading = false
    @Published private(set) var shortcutWarnings: [KeyboardShortcuts.Name: String] = [:]
    let screenTools: ScreenTools
    let recorder: ScreenRecorder
    private let shelf: ShelfController
    private let hud = InputHUD()
    private var overlays: [NSPanel] = []
    private var counting = false
    private var session: Task<Void, Never>?
    private var scrollTask: Task<Void, Never>?
    private var preview: NSPanel?
    private var recents: NSPanel?
    private var recentsMonitor: Any?
    private var recentsLocalMonitor: Any?
    private var sharingPicker: NSSharingServicePicker?
    private var sharingDelegate: CaptureSharingDelegate?
    private var recentsObserver: NSObjectProtocol?
    private var progress: NSPanel?
    private var uploadTask: Task<Void, Never>?
    private var uploadGeneration = UUID()
    private var previewTimer: Task<Void, Never>?
    private var pins: [NSPanel] = []
    private var pinMonitor: Any?
    private var recordingObserver: AnyCancellable?
    private var lifecycleTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var latest: URL?
    var onIslandCapture: ((CGImage) -> Void)?
    private var regionSelection: ((CGRect, CaptureDisplay, CaptureWindow?) -> Void)?
    private var regions = CaptureRegions()
    private var scrollDone = false
    private var scrollCancelled = false
    private var clipboardCount = 0
    private var captureArea: CGRect?
    private var copied = Set<URL>()
    private var saved: [URL: (URL, Int?)] = [:]
    private(set) var mode = CaptureMode.screenshot
    private let cache: URL

    init(screenTools: ScreenTools, shelf: ShelfController, recorder: ScreenRecorder) {
        self.screenTools = screenTools
        self.recorder = recorder
        self.shelf = shelf
        cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("MacKit/Captures", isDirectory: true)
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ScreenshotSettings.self, from: $0) } ?? ScreenshotSettings()
        if let data = try? Data(contentsOf: cache.appendingPathComponent("history.json")), let entries = try? JSONDecoder().decode([CaptureHistoryEntry].self, from: data) {
            history = entries.filter { FileManager.default.fileExists(atPath: cache.appendingPathComponent($0.filename).path) }
        }
        if settings.latestShortcut || settings.uploadShortcut { latest = history.first(where: { $0.kind == .screenshot }).map { cache.appendingPathComponent($0.filename) } }
        let bindings: [(KeyboardShortcuts.Name, () -> Void)] = [
            (.captureArea, { [weak self] in self?.start() }),
            (.captureScroll, { [weak self] in self?.start(.scrolling) }),
            (.captureDisplay, { [weak self] in self?.start(displayOnly: true) }),
            (.captureLatest, { [weak self] in self?.editLatest() }),
            (.captureClipboard, { [weak self] in self?.editClipboard() }),
            (.captureUpload, { [weak self] in self?.uploadLatest() }),
            (.captureHistory, { [weak self] in self?.showHistory() })
        ]
        for (name, action) in bindings { KeyboardShortcuts.onKeyUp(for: name) { MainActor.assumeIsolated { action() } } }
        if let data = UserDefaults.standard.data(forKey: "screenshot.links"), let stored = try? JSONDecoder().decode([CaptureLink].self, from: data) {
            links = CaptureLinkPolicy.live(stored, now: Date())
        }
        recordingObserver = recorder.$lastRecording.compactMap { $0 }.sink { [weak self] url in
            Task { @MainActor in await self?.rememberRecording(url) }
        }
        lifecycleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneLinks() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneLinks() }
        }
        pruneExports(cache.appendingPathComponent("Drag"), age: 3600)
        pruneExports(cache.appendingPathComponent("Clipboard"), age: 86400)
        applyShortcuts()
    }

    func pickRegion(_ completion: @escaping (CGRect, CaptureDisplay, CaptureWindow?) -> Void) {
        guard !busy, !screenTools.isSelecting, scrollTask == nil else { return }
        regionSelection = completion
        start(.text)
        if !busy { regionSelection = nil }
    }

    func start(_ mode: CaptureMode = .screenshot, displayOnly: Bool = false) {
        guard !screenTools.isSelecting else { return }
        if scrollTask != nil { if mode == .scrolling || displayOnly { scrollDone = true }; return }
        if busy {
            if counting { session?.cancel(); cleanup() }
            return
        }
        guard ScreenshotHardware.permitted else {
            _ = CGRequestScreenCaptureAccess()
            if !ScreenshotHardware.permitted { permissionGuide(); return }
            return
        }
        busy = true
        counting = settings.delay > 0 && (mode == .screenshot || mode == .scrolling)
        self.mode = mode
        clipboardCount = NSPasteboard.general.changeCount
        session = Task { [weak self] in
            guard let self else { return }
            do {
                if mode == .screenshot || mode == .scrolling {
                    for value in (0..<settings.delay).reversed() {
                        status = "Capture in \(value + 1) · press the shortcut again to cancel"
                        showCountdown(value + 1, total: settings.delay)
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                counting = false
                progress?.orderOut(nil)
                progress = nil
                try Task.checkCancellation()
                if displayOnly {
                    guard let screen = pointerScreen else { cleanup(); return }
                    let shot = try await ScreenshotHardware.display(screen, settings: settings)
                    captureArea = nil
                    try Task.checkCancellation()
                    cleanup()
                    complete(shot.image, scale: shot.scale)
                    return
                }
                var options = settings
                if mode != .screenshot { options.includePointer = false }
                let windows = ScreenshotHardware.windows()
                for screen in NSScreen.screens {
                    guard let shot = try? await ScreenshotHardware.display(screen, settings: options) else { continue }
                    try Task.checkCancellation()
                    showOverlay(shot, windows: windows)
                }
                if overlays.isEmpty { throw ScreenshotHardware.CaptureError.unavailable }
            } catch is CancellationError { cleanup() }
            catch { cleanup(); notify("Could not capture the screen") }
        }
    }

    var pointerScreen: NSScreen? { NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main }

    private func showOverlay(_ shot: CaptureDisplay, windows: [CaptureWindow]) {
        let panel = KeyablePanel(contentRect: shot.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.sharingType = .none
        let view = CaptureOverlayView(shot: shot, controller: self, windows: windows)
        panel.contentView = view
        overlays.append(panel)
        panel.orderFrontRegardless()
        if shot.frame.contains(NSEvent.mouseLocation) { panel.makeKey(); panel.makeFirstResponder(view) }
    }

    func switchMode(_ mode: CaptureMode) {
        guard regionSelection == nil, mode != .recording || ScreenRecorder.isSupported else { return }
        self.mode = mode
        for panel in overlays { (panel.contentView as? CaptureOverlayView)?.modeChanged() }
    }

    func previous(_ shot: CaptureDisplay) -> CGRect? {
        regions.repeatArea(display: shot.id, bounds: CGRect(origin: .zero, size: shot.frame.size), connected: Set(NSScreen.screens.compactMap(\.displayID)))
    }

    func select(_ rect: CGRect, shot: CaptureDisplay, window: CaptureWindow? = nil, remembers: Bool = true) {
        guard busy else { return }
        if let selection = regionSelection {
            let center = CGPoint(x: shot.frame.minX + rect.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - shot.frame.maxY + rect.midY)
            let followed = window ?? ScreenshotHardware.windows().first { $0.owner != getpid() && $0.layer == 0 && $0.frame.contains(center) }
            regionSelection = nil
            cleanup()
            selection(rect, shot, followed)
            return
        }
        if remembers { regions.remember(rect, display: shot.id) }
        captureArea = CGRect(x: shot.frame.minX + rect.minX, y: shot.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        let selectedMode = mode
        for panel in overlays { panel.orderOut(nil) }
        overlays.removeAll()
        if selectedMode == .scrolling { beginScroll(rect, shot: shot); return }
        if selectedMode == .recording {
            session = Task {
                defer { cleanup() }
                guard recorder.phase == .idle, let screen = NSScreen.screens.first(where: { $0.displayID == shot.id }),
                      let prepared = try? await ScreenshotHardware.prepare(screen, settings: settings) else { return }
                await recorder.startPreview(prepared.filter, options: RecordingOptions(systemAudio: false), sourceRect: rect, showsCursor: false)
                MainWindowController.show()
                NotificationCenter.default.post(name: .openSidebarPage, object: SidebarPage.screenRecord)
            }
            return
        }
        session = Task {
            do {
                let image: CGImage
                if let window, selectedMode == .screenshot {
                    image = try await ScreenshotHardware.window(window.id, scale: shot.scale)
                } else {
                    let source: CGImage
                    if selectedMode == .screenshot && !settings.freeze {
                        try await Task.sleep(for: .milliseconds(120))
                        guard let screen = NSScreen.screens.first(where: { $0.displayID == shot.id }) else { throw ScreenshotHardware.CaptureError.unavailable }
                        source = try await ScreenshotHardware.display(screen, settings: settings).image
                    } else { source = shot.image }
                    guard let cropped = source.cropping(to: CaptureGeometry.pixels(rect, scale: shot.scale)) else { throw ScreenshotHardware.CaptureError.encoding }
                    image = cropped
                }
                cleanup()
                if selectedMode == .text { screenTools.recognize(image) } else { complete(image, scale: shot.scale) }
            } catch { cleanup(); notify("Capture failed") }
        }
    }

    func copyColor(_ color: ClipboardColor, ends: Bool) {
        screenTools.acceptColor(color)
        if ends { cancel() }
    }

    func cancel() { session?.cancel(); cleanup() }

    private func cleanup() {
        regionSelection = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        busy = false
        counting = false
        progress?.orderOut(nil)
        progress = nil
    }

    func notify(_ message: String) { status = message; hud.show(message, for: 1.5) }

    private func showCountdown(_ value: Int, total: Int) {
        let panel = progress ?? makePanel(size: CGSize(width: 82, height: 82))
        panel.contentViewController = NSHostingController(rootView: CaptureCountdown(value: value, total: total))
        if let frame = pointerScreen?.visibleFrame { panel.setFrameOrigin(CGPoint(x: frame.midX - 41, y: frame.maxY - 106)) }
        progress = panel
        panel.orderFrontRegardless()
    }

    private func permissionGuide() {
        progress?.orderOut(nil)
        let panel = makePanel(size: CGSize(width: 350, height: 250))
        if let frame = NSScreen.screens.first?.visibleFrame { panel.setFrameOrigin(CGPoint(x: frame.maxX - 370, y: frame.maxY - 270)) }
        panel.contentViewController = NSHostingController(rootView: CapturePermissionGuide(close: { panel.orderOut(nil) }))
        progress = panel
        panel.orderFrontRegardless()
    }

    private func complete(_ image: CGImage, scale: CGFloat) {
        onIslandCapture?(image)
        closePreview()
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let id = UUID()
            let url = cache.appendingPathComponent("\(id.uuidString).png")
            guard let data = CaptureImages.png(image, scale: scale) else { throw ScreenshotHardware.CaptureError.encoding }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            latest = url
            if let thumbnail = CaptureImages.png(CaptureImages.resized(image, factor: min(1, 360 / CGFloat(max(image.width, image.height)))), scale: 1) {
                try? thumbnail.write(to: thumbnailURL(for: url), options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: thumbnailURL(for: url).path)
            }
            let old = history
            history = CaptureRetention.keep([CaptureHistoryEntry(id: id, date: Date(), filename: url.lastPathComponent, bytes: data.count, scale: scale)] + history)
            for item in old where !history.contains(item) { removeHistoryFiles(item) }
            persistHistory()
            if settings.autoCopy, NSPasteboard.general.changeCount == clipboardCount { copy(url, scale: scale) }
            var succeeded = true
            switch settings.action {
            case .ask: break
            case .save: succeeded = save(url, scale: scale)
            case .saveAndCopy: succeeded = save(url, scale: scale); copy(url, scale: scale)
            case .copy: copy(url, scale: scale)
            case .edit: ScreenshotEditorBridge.open(url)
            }
            if settings.autoShelf, shelf.settings.isEnabled { shelf.add([ShelfItem(kind: .file, path: url.path)]) }
            if settings.action != .edit && (settings.action == .ask || settings.confirmationPreview || !succeeded) {
                showPreview(url, scale: scale, seconds: settings.action == .ask || !succeeded ? 12 : settings.confirmationSeconds)
            }
        } catch { notify("Could not store the capture") }
    }

    func thumbnailURL(for url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("thumbnail.png") }

    private func removeHistoryFiles(_ entry: CaptureHistoryEntry) {
        let url = historyURL(entry)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: thumbnailURL(for: url))
    }

    private func rememberRecording(_ source: URL) async {
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let id = UUID()
            let url = cache.appendingPathComponent("\(id.uuidString).\(source.pathExtension)")
            try FileManager.default.copyItem(at: source, to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            let entry = CaptureHistoryEntry(id: id, date: Date(), filename: url.lastPathComponent, bytes: size, scale: 1, kind: .recording)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = CGSize(width: 360, height: 360)
            generator.appliesPreferredTrackTransform = true
            if let frame = try? await generator.image(at: .zero), let png = CaptureImages.png(frame.image, scale: 1) {
                try? png.write(to: thumbnailURL(for: url), options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: thumbnailURL(for: url).path)
            }
            let old = history
            history = CaptureRetention.keep([entry] + history)
            for item in old where !history.contains(item) { removeHistoryFiles(item) }
            persistHistory()
        } catch { notify("Could not add recording to recents") }
    }

    func restore(_ entry: CaptureHistoryEntry) {
        if entry.kind == .recording { NSWorkspace.shared.open(historyURL(entry)) }
        else { showPreview(historyURL(entry), scale: entry.scale) }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            let url = cache.appendingPathComponent("history.json")
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func output(_ url: URL, scale: CGFloat) -> CGImage? {
        guard let image = TextRecognizer.image(at: url) else { return nil }
        return settings.saveAt1x ? CaptureImages.resized(image, factor: 1 / scale) : image
    }

    func copy(_ url: URL, scale: CGFloat) {
        guard let image = output(url, scale: scale), let png = CaptureImages.png(image, scale: settings.saveAt1x ? 1 : scale) else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = CGSize(width: CGFloat(image.width) / (settings.saveAt1x ? 1 : scale), height: CGFloat(image.height) / (settings.saveAt1x ? 1 : scale))
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = bitmap.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        if !settings.imageOnly, let export = export(image, scale: settings.saveAt1x ? 1 : scale) { item.setString(export.absoluteString, forType: .fileURL) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
        copied.insert(url)
        notify("Screenshot copied")
    }

    func export(_ image: CGImage, scale: CGFloat, drag: Bool = false) -> URL? {
        let folder = cache.appendingPathComponent(drag ? "Drag" : "Clipboard", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            pruneExports(folder, age: drag ? 3600 : 86400)
            guard let data = CaptureImages.png(image, scale: scale) else { return nil }
            let url = folder.appendingPathComponent("\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch { return nil }
    }

    private func pruneExports(_ folder: URL, age: TimeInterval) {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let entries = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []).compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.creationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, entry) in entries.enumerated() {
            bytes += entry.2
            if index >= 99 || bytes > 256 * 1024 * 1024 || Date().timeIntervalSince(entry.1) > age { try? FileManager.default.removeItem(at: entry.0) }
        }
    }

    func dragURL(_ url: URL, scale: CGFloat) -> URL? {
        guard let image = TextRecognizer.image(at: url) else { return nil }
        return export(image, scale: scale, drag: true)
    }

    func share(_ url: URL, scale: CGFloat) {
        guard let file = shareURL(url, scale: scale), let view = preview?.contentView else { return }
        pausePreview()
        let delegate = CaptureSharingDelegate { [weak self] succeeded in
            if succeeded { self?.closePreview() } else { self?.resumePreview(seconds: 12) }
        }
        let picker = NSSharingServicePicker(items: [file])
        picker.delegate = delegate
        sharingDelegate = delegate
        sharingPicker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func shareURL(_ url: URL, scale: CGFloat) -> URL? {
        guard let image = output(url, scale: scale) else { return nil }
        return export(image, scale: settings.saveAt1x ? 1 : scale, drag: true)
    }

    @discardableResult
    func save(_ url: URL, scale: CGFloat, choose: Bool = false) -> Bool {
        if !choose && saved[url] != nil { return true }
        guard let image = output(url, scale: scale), let data = CaptureImages.png(image, scale: settings.saveAt1x ? 1 : scale) else { return false }
        let manager = FileManager.default
        var folder = URL(fileURLWithPath: settings.folder, isDirectory: true)
        var directory: ObjCBool = false
        if settings.folder.isEmpty || !manager.fileExists(atPath: folder.path, isDirectory: &directory) || !directory.boolValue {
            folder = manager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        }
        let base = folder
        for component in CaptureNames.subfolders(settings.subfolder, date: Date()) { folder.appendPathComponent(component, isDirectory: true) }
        do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) } catch { folder = base }
        let name = CaptureNames.filename(pattern: settings.pattern, date: Date(), counter: settings.counter)
        var destination = CaptureNames.available(folder.appendingPathComponent(name)) { manager.fileExists(atPath: $0.path) }
        if choose {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = name
            panel.directoryURL = folder
            guard panel.runModal() == .OK else { return false }
            destination = panel.url
        }
        guard let destination else { notify("No available filename"); return false }
        do {
            try data.write(to: destination, options: .atomic)
            let usesCounter = CaptureNames.usesCounter(settings.pattern)
            saved[url] = (destination, usesCounter ? settings.counter : nil)
            if usesCounter { settings.counter = (settings.counter + 1) % 1_000_000 }
            let attribute = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
            attribute.withUnsafeBytes { bytes in
                _ = setxattr(destination.path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, bytes.count, 0, 0)
            }
            notify("Screenshot saved")
            return true
        } catch { notify("Could not save screenshot"); return false }
    }

    func wasSaved(_ url: URL) -> Bool { saved[url] != nil }
    func wasCopied(_ url: URL) -> Bool { copied.contains(url) }

    func discard(_ url: URL) {
        copied.remove(url)
        if let (destination, counter) = saved.removeValue(forKey: url) {
            try? FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            if let counter, settings.counter == (counter + 1) % 1_000_000 { settings.counter = counter }
        }
        shelf.remove(Set(shelf.items.filter { $0.path == url.path }.map(\.id)))
        history.removeAll { $0.filename == url.lastPathComponent }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: thumbnailURL(for: url))
        if latest == url { latest = nil }
        persistHistory()
        closePreview()
    }

    func editLatest() {
        guard let latest, FileManager.default.fileExists(atPath: latest.path) else { notify("No latest screenshot"); return }
        ScreenshotEditorBridge.open(latest)
    }

    func editClipboard() {
        guard let image = NSImage(pasteboard: .general), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = CaptureImages.png(cg, scale: 1) else { notify("Clipboard has no image"); return }
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let url = cache.appendingPathComponent("clipboard-\(UUID().uuidString).png")
            try data.write(to: url, options: .atomic)
            ScreenshotEditorBridge.open(url)
        } catch { notify("Could not open clipboard image") }
    }

    func uploadLatest() {
        guard let latest else { notify("No latest screenshot"); return }
        upload(latest, scale: history.first(where: { $0.filename == latest.lastPathComponent })?.scale ?? 1)
    }

    func upload(_ url: URL, scale: CGFloat) {
        guard settings.allowLinks, let backend = CaptureLinkPolicy.endpoint(settings.backend) else { notify("Enable links and configure an HTTPS backend first"); return }
        guard !uploading, let image = output(url, scale: scale), let data = CaptureImages.png(image, scale: settings.saveAt1x ? 1 : scale),
              data.count <= CaptureLinkPolicy.maxBytes else { notify("Link uploads are limited to 25 MB"); return }
        pausePreview()
        uploading = true
        let generation = UUID()
        uploadGeneration = generation
        let hours = settings.linkHours
        uploadTask = Task {
            do {
                let client = CaptureLinkClient()
                let link = try await client.upload(data, backend: backend, hours: hours)
                guard uploadGeneration == generation else { try? await client.delete(link); uploading = false; return }
                links = CaptureLinkPolicy.live(links, now: Date()) + [link]
                persistLinks()
                ScreenTools.copy(link.url.absoluteString)
                uploading = false
                closePreview()
                notify("Temporary link copied")
            } catch {
                uploading = false
                notify("Upload failed; check the backend configuration")
                resumePreview(seconds: 12)
            }
        }
    }

    func deleteLink(_ link: CaptureLink) {
        Task {
            do {
                try await CaptureLinkClient().delete(link)
                links.removeAll { $0.id == link.id }
                persistLinks()
            } catch { notify("Could not delete the link") }
        }
    }

    func pruneLinks() { links = CaptureLinkPolicy.live(links, now: Date()); persistLinks() }
    private func persistLinks() { UserDefaults.standard.set(try? JSONEncoder().encode(links), forKey: "screenshot.links") }

    func makePanel(size: CGSize) -> NSPanel {
        let panel = KeyablePanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        if let frame = pointerScreen?.visibleFrame { panel.setFrameOrigin(CGPoint(x: frame.maxX - size.width - 16, y: frame.minY + 16)) }
        return panel
    }

    func showPreview(_ url: URL, scale: CGFloat, seconds: Int = 12) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            history.removeAll { $0.filename == url.lastPathComponent }
            persistHistory()
            notify("This capture is no longer available")
            return
        }
        closePreview()
        let panel = makePanel(size: CGSize(width: 350, height: 230))
        panel.contentViewController = NSHostingController(rootView: CapturePreview(controller: self, url: url, scale: scale, seconds: seconds))
        if let frame = pointerScreen?.visibleFrame {
            panel.setFrameOrigin(CapturePlacement.preview(size: panel.frame.size, screen: frame, area: settings.action == .ask ? captureArea : nil,
                                                         pointer: NSEvent.mouseLocation, corner: settings.corner))
        }
        preview = panel
        if settings.previewTakesFocus && seconds > 0 { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        resumePreview(seconds: seconds)
    }

    func pausePreview() { previewTimer?.cancel() }
    func resumePreview(seconds: Int) {
        previewTimer?.cancel()
        guard seconds > 0, !uploading else { return }
        previewTimer = Task { try? await Task.sleep(for: .seconds(seconds)); if !Task.isCancelled { closePreview() } }
    }
    func closePreview() { uploadGeneration = UUID(); pausePreview(); preview?.orderOut(nil); preview = nil }

    func showHistory() {
        closeHistory()
        let panel = makePanel(size: CGSize(width: 440, height: 380))
        panel.contentViewController = NSHostingController(rootView: CaptureHistoryView(controller: self) { self.closeHistory() })
        recents = panel
        panel.makeKeyAndOrderFront(nil)
        recentsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeHistory() }
        }
        recentsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak panel] event in
            if event.window !== panel { MainActor.assumeIsolated { self?.closeHistory() } }
            return event
        }
        recentsObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeHistory() }
        }
    }

    func closeHistory() {
        recents?.orderOut(nil)
        recents = nil
        if let recentsMonitor { NSEvent.removeMonitor(recentsMonitor); self.recentsMonitor = nil }
        if let recentsLocalMonitor { NSEvent.removeMonitor(recentsLocalMonitor); self.recentsLocalMonitor = nil }
        if let recentsObserver { NSWorkspace.shared.notificationCenter.removeObserver(recentsObserver); self.recentsObserver = nil }
    }

    func historyURL(_ item: CaptureHistoryEntry) -> URL { cache.appendingPathComponent(item.filename) }

    func pin(_ url: URL, scale: CGFloat) {
        guard let image = TextRecognizer.image(at: url) else { return }
        let limit: CGFloat = min(pointerScreen?.frame.width ?? 900, pointerScreen?.frame.height ?? 700) * 0.55
        let factor: CGFloat = min(CGFloat(1) / scale, limit / CGFloat(max(image.width, image.height)))
        let size = CGSize(width: max(90, CGFloat(image.width) * factor), height: max(60, CGFloat(image.height) * factor))
        let panel = makePanel(size: size)
        panel.styleMask.insert(.resizable)
        panel.contentAspectRatio = CGSize(width: image.width, height: image.height)
        panel.isMovableByWindowBackground = true
        panel.contentViewController = NSHostingController(rootView: CapturePin(controller: self, panel: panel, url: url, scale: scale))
        if let frame = pointerScreen?.visibleFrame {
            let offset = CGFloat(pins.count % 5) * 26
            panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2 + offset, y: frame.midY - size.height / 2 - offset))
        }
        pins.append(panel)
        panel.orderFrontRegardless()
    }

    func ignorePinClicks(_ panel: NSPanel) {
        panel.ignoresMouseEvents = true
        guard pinMonitor == nil else { return }
        pinMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard event.modifierFlags.contains(.option) else { return }
            MainActor.assumeIsolated {
                for pin in self?.pins ?? [] where pin.frame.contains(NSEvent.mouseLocation) { pin.ignoresMouseEvents = false }
            }
        }
    }

    func closePins() {
        pins.forEach { $0.orderOut(nil) }
        pins.removeAll()
        if let pinMonitor { NSEvent.removeMonitor(pinMonitor); self.pinMonitor = nil }
    }

    func validateShortcut(_ name: KeyboardShortcuts.Name) {
        KeyboardShortcuts.disable([name])
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else {
            shortcutWarnings[name] = "Choose a shortcut to enable this action."
            return
        }
        var reference: EventHotKeyRef?
        let result = RegisterEventHotKey(UInt32(shortcut.carbonKeyCode), UInt32(shortcut.carbonModifiers),
                                         EventHotKeyID(signature: 0x4D4B4350, id: 1), GetEventDispatcherTarget(), 0, &reference)
        if let reference { UnregisterEventHotKey(reference) }
        if result == noErr {
            shortcutWarnings[name] = nil
            KeyboardShortcuts.enable([name])
        } else { shortcutWarnings[name] = "This shortcut could not be registered (\(result)). Choose another combination." }
    }

    private func applyShortcuts() {
        let items: [(KeyboardShortcuts.Name, Bool)] = [(.captureArea, settings.areaShortcut), (.captureScroll, settings.scrollingShortcut),
            (.captureDisplay, settings.displayShortcut), (.captureLatest, settings.latestShortcut), (.captureClipboard, settings.clipboardShortcut),
            (.captureUpload, settings.uploadShortcut), (.captureHistory, settings.historyShortcut)]
        for (name, enabled) in items { if enabled { validateShortcut(name) } else { KeyboardShortcuts.disable([name]); shortcutWarnings[name] = nil } }
    }

    private func beginScroll(_ rect: CGRect, shot: CaptureDisplay) {
        scrollDone = false
        scrollCancelled = false
        scrollHeight = 0
        let outline = makePanel(size: shot.frame.size)
        outline.setFrame(shot.frame, display: false)
        outline.contentView = CaptureScrollOutline(frame: CGRect(origin: .zero, size: shot.frame.size), area: rect)
        outline.ignoresMouseEvents = true
        outline.orderFrontRegardless()
        overlays.append(outline)
        let panel = makePanel(size: CGSize(width: 380, height: 100))
        if let screen = pointerScreen { panel.setFrameOrigin(CGPoint(x: screen.frame.midX - 190, y: screen.visibleFrame.maxY - 124)) }
        panel.contentViewController = NSHostingController(rootView: CaptureScrollProgress(controller: self))
        panel.makeKeyAndOrderFront(nil)
        let scrollPoint = CGPoint(x: shot.frame.minX + rect.midX, y: shot.frame.maxY - rect.midY)
        if panel.frame.contains(scrollPoint) { panel.setFrameOrigin(CGPoint(x: panel.frame.minX, y: shot.frame.minY + 24)) }
        progress = panel
        scrollTask = Task {
            var assembled: CGImage?
            var tracker = ScrollTracker()
            var budget = ScrollBudget(width: Int(rect.width * shot.scale), started: Date())
            var quiet = 0
            var options = settings
            options.includePointer = false
            let crop = CaptureGeometry.pixels(rect, scale: shot.scale, even: true)
            let point = CGPoint(x: shot.frame.minX + rect.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - shot.frame.maxY + rect.midY)
            let candidates = ScreenshotHardware.windows().filter { $0.owner != getpid() }
            let target = CaptureWindows.hit(point, windows: candidates, excluding: [])
            let screen = NSScreen.screens.first(where: { $0.displayID == shot.id })
            let prepared: ScreenshotHardware.Prepared?
            if let screen { prepared = try? await ScreenshotHardware.prepare(screen, settings: options) } else { prepared = nil }
            while !scrollCancelled {
                do {
                    guard NSScreen.screens.contains(where: { $0.displayID == shot.id }), let prepared else { throw ScreenshotHardware.CaptureError.unavailable }
                    if settings.automaticScroll {
                        let current = CaptureWindows.hit(point, windows: ScreenshotHardware.windows().filter { $0.owner != getpid() }, excluding: [])
                        guard AXIsProcessTrusted(), current?.id == target?.id, current?.frame == target?.frame else {
                            notify("Scrolling target changed; keeping completed capture")
                            break
                        }
                    }
                    let frame = try await prepared.capture()
                    guard let image = frame.image.cropping(to: crop) else { throw ScreenshotHardware.CaptureError.encoding }
                    let gray = CaptureImages.gray(image)
                    var added = 0
                    switch tracker.ingest(gray) {
                    case .append(let rows, let footer):
                        guard (2 * budget.height + rows + image.height) * image.width <= 60_000_000, budget.accept(rows: rows, now: Date()) else { notify("Capture kept at safe limit"); scrollDone = true; break }
                        added = rows
                        if let base = assembled { assembled = CaptureImages.append(base, frame: image, rows: rows, footer: footer) ?? base }
                        else { assembled = image }
                    case .unchanged, .repositioned:
                        if !budget.accept(rows: 0, now: Date()) { notify("Capture kept at safe limit"); scrollDone = true }
                    case .mismatch:
                        notify("Content changed; keeping completed capture")
                        scrollDone = true
                    }
                    scrollHeight = assembled?.height ?? 0
                    quiet = added == 0 ? quiet + 1 : 0
                    if scrollDone { break }
                    if settings.automaticScroll {
                        guard AXIsProcessTrusted(), quiet < 3 else { break }
                        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -Int32(min(160, max(1, rect.height * 0.15))), wheel2: 0, wheel3: 0)
                        event?.location = point
                        event?.setIntegerValueField(.eventSourceUserData, value: InputController.marker)
                        event?.post(tap: .cghidEventTap)
                    }
                    try await Task.sleep(for: .milliseconds(settings.automaticScroll ? 550 : 90))
                    if settings.automaticScroll || scrollDone {
                        let deadline = Date().addingTimeInterval(scrollDone ? 0.85 : 0.95)
                        var previousSample: GrayFrame?
                        while Date() < deadline {
                            let settledFrame = try await prepared.capture()
                            guard let cropped = settledFrame.image.cropping(to: crop) else { break }
                            let sample = CaptureImages.gray(cropped)
                            if sample == previousSample { break }
                            previousSample = sample
                            try await Task.sleep(for: .milliseconds(90))
                        }
                    }
                } catch { notify("Capture stopped; keeping completed content"); break }
            }
            panel.orderOut(nil)
            progress = nil
            scrollTask = nil
            cleanup()
            if scrollCancelled { notify("Capture cancelled") }
            else if let assembled { complete(CaptureImages.trimTransparent(assembled), scale: shot.scale) }
            else { notify("No scrolling content captured") }
        }
    }

    func finishScroll(cancel: Bool) { scrollCancelled = cancel; scrollDone = true }
}

@MainActor
private enum WindowBufferCapture {
    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    static let library = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    static func image(id: CGWindowID, frame: CGRect, scale: CGFloat) -> CGImage? {
        guard ScreenshotHardware.permitted,
              NSScreen.screens.contains(where: { screen in
                  let top = (NSScreen.screens.first?.frame.maxY ?? 0) - screen.frame.maxY
                  return CGRect(x: screen.frame.minX, y: top, width: screen.frame.width, height: screen.frame.height).contains(frame)
              }), let library, let symbol = dlsym(library, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        guard let image = capture(.null, CGWindowListOption.optionIncludingWindow.rawValue, id,
                                  CGWindowImageOption.boundsIgnoreFraming.rawValue | CGWindowImageOption.bestResolution.rawValue)?.takeRetainedValue(),
              image.width >= Int(frame.width * scale), image.height >= Int(frame.height * scale) else { return nil }
        return image
    }
}
