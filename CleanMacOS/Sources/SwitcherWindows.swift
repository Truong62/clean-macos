import AppKit
import ApplicationServices
import ScreenCaptureKit

struct SwitcherWindowSnapshot {
    var windows: [SwitcherWindow]
    var elements: [String: AXUIElement]
    var focused: String?
}

enum SwitcherWindowAccess {
    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowIDFunction: WindowIDFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()

    static func windowID(_ element: AXUIElement) -> UInt32? {
        var id: CGWindowID = 0
        guard windowIDFunction?(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    static func snapshot(apps: [NSRunningApplication], frontPID: Int32?) -> SwitcherWindowSnapshot {
        let server = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let index = Dictionary(server.enumerated().compactMap { offset, value -> (UInt32, (Int, [String: Any]))? in
            guard let id = value[kCGWindowNumber as String] as? UInt32 else { return nil }
            return (id, (offset, value))
        }, uniquingKeysWith: { first, _ in first })
        let result = SnapshotAccumulator()
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: 24)
        let deadline = DispatchTime.now() + 5
        for app in apps {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                guard slots.wait(timeout: deadline) == .success else { return }
                defer { slots.signal() }
                guard DispatchTime.now() < deadline else { return }
                let pid = app.processIdentifier
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.1)
                let elements: [AXUIElement] = AXWindow.value(application, kAXWindowsAttribute) ?? []
                let focused: AXUIElement? = pid == frontPID ? AXWindow.value(application, kAXFocusedWindowAttribute) : nil
                var windows: [SwitcherWindow] = []
                var handles: [String: AXUIElement] = [:]
                var focusedID: String?
                for element in elements {
                    guard DispatchTime.now() < deadline else { break }
                    AXUIElementSetMessagingTimeout(element, 0.35)
                    let attributes = [kAXRoleAttribute, kAXSubroleAttribute, "AXFullScreen", kAXMinimizedAttribute,
                                      kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute] as CFArray
                    var raw: CFArray?
                    guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &raw) == .success,
                          let values = raw as? [Any], values.count == 7 else { continue }
                    let role = values[0] as? String
                    let subrole = values[1] as? String
                    let minimized = values[3] as? Bool ?? false
                    guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole || subrole == "AXUnknown" || minimized else { continue }
                    let frame = AXWindow.frame(element) ?? .zero
                    let windowID = windowID(element)
                    let info = windowID.flatMap { index[$0] }
                    let axTitle = values[6] as? String ?? ""
                    let title = (info?.1[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? axTitle
                    if pid == getpid() && (title.isEmpty || (!minimized && info?.1[kCGWindowIsOnscreen as String] as? Bool != true)) { continue }
                    let id = "\(pid):\(windowID.map(String.init) ?? String(CFHash(element)))"
                    let fullScreen = values[2] as? Bool ?? false
                    let onScreen = info?.1[kCGWindowIsOnscreen as String] as? Bool ?? false
                    windows.append(SwitcherWindow(id: id, windowID: windowID, pid: pid, bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "App",
                                                  title: title, frame: frame, zOrder: info?.0 ?? Int.max,
                                                  layer: info?.1[kCGWindowLayer as String] as? Int ?? 0,
                                                  alpha: info?.1[kCGWindowAlpha as String] as? Double ?? 1,
                                                  minimized: minimized, fullScreen: fullScreen, hidden: app.isHidden,
                                                  otherDesktop: !onScreen && !minimized && !app.isHidden, isOnScreen: onScreen))
                    handles[id] = element
                    if let focused, CFEqual(element, focused) { focusedID = id }
                }
                if windows.isEmpty {
                    windows.append(SwitcherWindow(id: "app:\(pid)", windowID: nil, pid: pid, bundleID: app.bundleIdentifier ?? "",
                                                  appName: app.localizedName ?? "App", title: "", frame: .zero, zOrder: Int.max, hidden: app.isHidden))
                }
                result.append(windows, elements: handles, focused: focusedID)
            }
        }
        _ = group.wait(timeout: deadline)
        return result.value()
    }

    private final class SnapshotAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot = SwitcherWindowSnapshot(windows: [], elements: [:], focused: nil)
        func append(_ windows: [SwitcherWindow], elements: [String: AXUIElement], focused: String?) {
            lock.lock()
            defer { lock.unlock() }
            snapshot.windows += windows
            snapshot.elements.merge(elements) { _, new in new }
            if let focused { snapshot.focused = focused }
        }
        func value() -> SwitcherWindowSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }
    }

    static func close(_ element: AXUIElement) {
        guard let button: AXUIElement = AXWindow.value(element, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    static func minimize(_ element: AXUIElement, value: Bool) {
        let result = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
        if result != .success, let button: AXUIElement = AXWindow.value(element, kAXMinimizeButtonAttribute) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }
}

@MainActor
final class SwitcherActivation {
    private var task: Task<Void, Never>?

    func cancel() { task?.cancel(); task = nil }

    func activate(_ window: SwitcherWindow, element: AXUIElement?) {
        cancel()
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        task = Task {
            if app.isHidden { app.unhide() }
            if window.isWindowless {
                app.activate()
                if let url = app.bundleURL { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil) }
                return
            }
            guard let element else { app.activate(); return }
            app.activate()
            if window.minimized {
                for _ in 0..<10 {
                    guard !Task.isCancelled else { return }
                    if app.isActive { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard app.isActive, !Task.isCancelled else { return }
                SwitcherWindowAccess.minimize(element, value: false)
            }
            for delay in [0, 120, 260, 300] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard !Task.isCancelled else { return }
                AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            }
        }
    }
}

actor SwitcherCaptureQueue {
    static let shared = SwitcherCaptureQueue()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func capture(_ window: SwitcherWindow, longestEdge: CGFloat) async throws -> CGImage? {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let candidates = content.windows.filter { $0.owningApplication?.processID == window.pid }
        let match = candidates.first { $0.windowID == window.windowID }
            ?? candidates.first { !$0.title.orEmpty.isEmpty && $0.title == window.title }
            ?? candidates.min { a, b in Self.distance(a.frame, window.frame) < Self.distance(b.frame, window.frame) }
        guard let match, match.frame.width > 0, match.frame.height > 0 else { return nil }
        let ratio = longestEdge / max(match.frame.width, match.frame.height)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(match.frame.width * ratio))
        config.height = max(1, Int(match.frame.height * ratio))
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: match), configuration: config)
        guard let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bitmap.makeImage()
    }

    func capture(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration)
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

@MainActor
final class SwitcherThumbnails: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    private var policy = ThumbnailPolicy()
    private var task: Task<Void, Never>?
    private var pressure: DispatchSourceMemoryPressure?
    private var permission = false
    var active = true

    init() {
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .main)
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.cancel(); self?.images.removeAll(); self?.policy.clear() }
        }
        pressure.resume()
        self.pressure = pressure
    }

    func cancel() { task?.cancel(); task = nil }

    func refresh(_ windows: [SwitcherWindow], size: PreviewSize, dock: Bool, simple: Bool, pausedApps: [String]) {
        cancel()
        let now = ProcessInfo.processInfo.systemUptime
        let app = NSWorkspace.shared.frontmostApplication
        let paused = pausedApps.contains(app?.bundleIdentifier ?? "") || pausedApps.contains(app?.executableURL?.path ?? "")
        guard !simple, active, !paused, now >= policy.pausedUntil else { return }
        let before = ProcessInfo.processInfo.systemUptime
        if policy.preflight(now: before) {
            permission = CGPreflightScreenCaptureAccess()
            policy.health(duration: ProcessInfo.processInfo.systemUptime - before, permissionCheck: true, now: before)
        }
        guard policy.canCapture(now: now, permission: permission, active: active, simple: simple, pausedApp: paused) else { return }
        for window in windows { policy.touch(window.id, now: now) }
        task = Task { [weak self] in
            for window in windows where !window.isWindowless {
                guard let self, !Task.isCancelled, self.active else { return }
                let start = ProcessInfo.processInfo.systemUptime
                guard start >= self.policy.pausedUntil else { return }
                let image = try? await SwitcherCaptureQueue.shared.capture(window, longestEdge: (dock ? 420 : 640) * size.scale)
                let end = ProcessInfo.processInfo.systemUptime
                self.policy.health(duration: end - start, permissionCheck: false, now: end)
                guard !Task.isCancelled else { return }
                if let image {
                    let removed = self.policy.insert(window.id, bytes: image.bytesPerRow * image.height, now: end)
                    self.images[window.id] = NSImage(cgImage: image, size: .zero)
                    for id in removed { self.images.removeValue(forKey: id) }
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
    }

    func prune(_ ids: Set<String>) {
        policy.prune(ids)
        images = images.filter { ids.contains($0.key) }
    }
}

@MainActor
final class SwitcherFocusObserver {
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var pid: Int32?
    private var retry: Task<Void, Never>?
    var onFocus: ((String, Int32) -> Void)?

    func watch(_ pid: Int32?) {
        guard self.pid != pid else { return }
        stop()
        guard let pid else { return }
        self.pid = pid
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SwitcherFocusObserver>.fromOpaque(context).takeUnretainedValue().read()
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        observer = created
        application = app
        for notification in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(created, app, notification as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        read()
        retry = Task {
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                read()
            }
        }
    }

    private func read() {
        guard let app = application, let pid, let focused: AXUIElement = AXWindow.value(app, kAXFocusedWindowAttribute) else { return }
        let identifier = SwitcherWindowAccess.windowID(focused).map(String.init) ?? String(CFHash(focused))
        onFocus?("\(pid):\(identifier)", pid)
    }

    func stop() {
        retry?.cancel()
        retry = nil
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        application = nil
        pid = nil
    }
}
