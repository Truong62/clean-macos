import AppKit

struct ClipboardSnapshot {
    let facts: PasteboardFacts
    let text: String?
    let image: Data?
    let files: [String]
}

final class ClipboardMonitor {
    static let maxTextLength = 1_000_000
    static let maxFiles = 100
    static let maxPNGBytes = 16 * 1_048_576
    static let maxTIFFBytes = 64 * 1_048_576

    var onChange: ((ClipboardSnapshot) -> Void)?
    var onTick: (() -> Void)?
    var onSkip: (() -> Void)?
    var shouldSkip: ((PasteboardFacts) -> Bool)?
    var readsImagesAndFiles = true
    private(set) var lastChangeDate = Date()

    private var timer: DispatchSourceTimer?
    private var lastChangeCount: Int
    private var activatedApps: Set<String> = []
    private var activationObserver: NSObjectProtocol?
    private let pasteboard: NSPasteboard
    private let interval: TimeInterval

    init(pasteboard: NSPasteboard = .general, interval: TimeInterval = 0.5) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit {
        timer?.cancel()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func start() {
        stop()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                               object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, let id = app.bundleIdentifier else { return }
            self?.activatedApps.insert(id)
        }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.poll() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    func ignoreCurrentChange() {
        lastChangeCount = pasteboard.changeCount
        lastChangeDate = Date()
    }

    static func isCapturable(_ text: String) -> Bool {
        text.count <= maxTextLength && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func poll() {
        onTick?()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let apps = activatedApps.union([frontmost].compactMap { $0 })
        activatedApps = Set([frontmost].compactMap { $0 })
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        lastChangeDate = Date()
        let facts = PasteboardFacts(types: Set((pasteboard.types ?? []).map(\.rawValue)),
                                    declaredSource: pasteboard.string(forType: .init(PasteboardFacts.source)), activeApps: apps)
        guard shouldSkip?(facts) != true else {
            onSkip?()
            return
        }
        onChange?(read(facts))
    }

    private func read(_ facts: PasteboardFacts) -> ClipboardSnapshot {
        let urls = readsImagesAndFiles ? pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] : nil
        let files = (urls ?? []).prefix(Self.maxFiles).map(\.path)
        let text = files.isEmpty ? readText() : nil
        let wantsImage = readsImagesAndFiles && files.isEmpty && ClipboardCapture.kind(hasFiles: false, hasImage: true, text: text) == .image
        return ClipboardSnapshot(facts: facts, text: text, image: wantsImage ? readImage() : nil, files: Array(files))
    }

    private func readText() -> String? {
        if let string = pasteboard.string(forType: .string), !string.isEmpty { return string }
        return PlainText.extract(string: nil, rtf: pasteboard.data(forType: .rtf), html: pasteboard.data(forType: .html))
    }

    private func readImage() -> Data? {
        if let png = pasteboard.data(forType: .png) { return png.count <= Self.maxPNGBytes ? png : nil }
        guard let tiff = pasteboard.data(forType: .tiff), tiff.count <= Self.maxTIFFBytes,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]), png.count <= Self.maxPNGBytes else { return nil }
        return png
    }
}
