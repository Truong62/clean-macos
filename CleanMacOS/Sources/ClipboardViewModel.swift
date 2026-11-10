import AppKit
import CryptoKit
import KeyboardShortcuts
import SwiftUI

@MainActor
final class ClipboardViewModel: ObservableObject {
    static let retentionCheck: TimeInterval = 3600
    static let restoreDelay: TimeInterval = 0.5
    static let modifierWait: TimeInterval = 1.5
    static let thumbnailSize = 320
    static let screenLocked = Notification.Name("com.apple.screenIsLocked")

    @Published private(set) var items: [ClipboardItem] = []
    @Published var options: ClipboardOptions {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(options), forKey: ClipboardOptions.key)
            applyOptions(previous: oldValue)
        }
    }

    private var history: ClipboardHistory
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor
    private var isStarted = false
    private var retentionTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let thumbnails = NSCache<NSString, NSImage>()

    init(store: ClipboardStore = ClipboardStore(), monitor: ClipboardMonitor = ClipboardMonitor()) {
        self.store = store
        self.monitor = monitor
        options = UserDefaults.standard.data(forKey: ClipboardOptions.key).flatMap { try? JSONDecoder().decode(ClipboardOptions.self, from: $0) }
            ?? ClipboardOptions()
        history = ClipboardHistory(items: ClipboardSettings.persist ? store.load() : [])
        items = history.items
        monitor.readsImagesAndFiles = options.savesImagesAndFiles
        monitor.shouldSkip = { [weak self] facts in
            MainActor.assumeIsolated {
                guard let self else { return true }
                return ClipboardFilter.shouldSkip(facts, options: self.options, skipsConcealed: ClipboardSettings.skipConcealed)
            }
        }
        monitor.onChange = { [weak self] snapshot in MainActor.assumeIsolated { self?.capture(snapshot) } }
        monitor.onTick = { [weak self] in MainActor.assumeIsolated { self?.clearIfDue() } }
        pruneExpired()
        commit()
    }

    var pinnedItems: [ClipboardItem] { items.filter(\.isPinned) }
    var recentItems: [ClipboardItem] { items.filter { !$0.isPinned } }

    func startMonitoring() {
        guard !isStarted else { return }
        isStarted = true
        monitor.start()
        KeyboardShortcuts.onKeyUp(for: .pastePlainText) { [weak self] in
            MainActor.assumeIsolated { self?.pastePlainText() }
        }
        retentionTimer = Timer.scheduledTimer(withTimeInterval: Self.retentionCheck, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pruneExpired()
                self?.commit()
            }
        }
        observeClearEvents()
        applyOptions(previous: nil)
    }

    func add(_ text: String) {
        insert(ClipboardItem(text: text))
    }

    @discardableResult
    func copy(_ item: ClipboardItem) -> Bool {
        let pasteboard = NSPasteboard.general
        switch item.kind {
        case .text:
            pasteboard.clearContents()
            pasteboard.setString(item.text, forType: .string)
        case .image:
            guard let name = item.image?.fileName, let png = try? Data(contentsOf: store.imageURL(named: name)) else { return refuse() }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
        case .files:
            let urls = item.files.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return refuse() }
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        }
        monitor.ignoreCurrentChange()
        var used = item
        used.createdAt = Date()
        used.sourceApp = nil
        insert(used)
        return true
    }

    func delete(_ item: ClipboardItem) {
        history.remove(id: item.id)
        commit()
    }

    func delete(_ ids: Set<ClipboardItem.ID>) {
        history.remove(ids: ids)
        commit()
    }

    func clearAll() {
        history.clear()
        commit()
    }

    func togglePin(_ item: ClipboardItem) {
        history.togglePin(id: item.id, at: Date())
        commit()
    }

    func update(_ item: ClipboardItem, text: String) {
        history.update(id: item.id, text: text)
        commit()
    }

    func persistenceSettingChanged() {
        if ClipboardSettings.persist {
            store.save(items)
        } else {
            store.delete()
        }
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        item.image.map { store.imageURL(named: $0.fileName) }
    }

    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard let name = item.image?.fileName else { return nil }
        if let cached = thumbnails.object(forKey: name as NSString) { return cached }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailSize] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(store.imageURL(named: name) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails.setObject(thumbnail, forKey: name as NSString)
        return thumbnail
    }

    func pastePlainText() {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard PasteService.isAccessibilityTrusted else {
            PasteService.requestAccessibility()
            NSSound.beep()
            return
        }
        guard files.isEmpty, let text = PlainText.extract(string: pasteboard.string(forType: .string), rtf: pasteboard.data(forType: .rtf),
                                                          html: pasteboard.data(forType: .html)) else {
            NSSound.beep()
            return
        }
        let backup = PasteboardBackup(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: .init(PasteboardFacts.transient))
        let written = pasteboard.changeCount
        PasteService.pasteWhenModifiersReleased(timeout: Self.modifierWait) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelay) {
                guard pasteboard.changeCount == written else { return }
                backup.restore(to: pasteboard)
            }
        }
    }

    private func capture(_ snapshot: ClipboardSnapshot) {
        let source = ClipboardFilter.sourceApp(snapshot.facts)
        switch ClipboardCapture.kind(hasFiles: !snapshot.files.isEmpty, hasImage: snapshot.image != nil, text: snapshot.text) {
        case .files:
            insert(ClipboardItem(text: "", kind: .files, sourceApp: source, files: snapshot.files))
        case .image:
            if let png = snapshot.image { captureImage(png, source: source) }
        case .text:
            if let text = snapshot.text { captureText(text, facts: snapshot.facts, source: source) }
        case nil:
            return
        }
    }

    private func captureText(_ text: String, facts: PasteboardFacts, source: String?) {
        guard ClipboardMonitor.isCapturable(text), !(options.skipsSensitiveText && SensitiveText.looksSensitive(text)) else { return }
        if options.cleansURLs, facts.holdsOnlyText, let cleaned = URLCleaner.clean(text, rules: options.urlRules), !cleaned.removed.isEmpty {
            rewritePasteboard(with: cleaned.url, facts: facts)
            return
        }
        insert(ClipboardItem(text: text, sourceApp: source))
    }

    private func captureImage(_ png: Data, source: String?) {
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        if let existing = history.items.first(where: { $0.image?.hash == hash }) {
            insert(ClipboardItem(text: "", kind: .image, sourceApp: source, image: existing.image))
            return
        }
        guard let bitmap = NSBitmapImageRep(data: png) else { return }
        let id = UUID()
        let info = ClipboardItem.ImageInfo(fileName: id.uuidString + ".png", hash: hash, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        guard store.saveImage(png, named: info.fileName) else { return }
        insert(ClipboardItem(id: id, text: "", kind: .image, sourceApp: source, image: info))
    }

    private func rewritePasteboard(with link: String, facts: PasteboardFacts) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        if facts.types.contains(NSPasteboard.PasteboardType.URL.rawValue) { pasteboard.setString(link, forType: .URL) }
        if let source = facts.declaredSource { pasteboard.setString(source, forType: .init(PasteboardFacts.source)) }
    }

    private func insert(_ item: ClipboardItem) {
        history.insert(item, maxItems: ClipboardSettings.maxItems)
        pruneExpired()
        commit()
    }

    private func pruneExpired() {
        guard options.retentionDays > 0 else { return }
        history.prune(before: Date(timeIntervalSinceNow: -Double(options.retentionDays) * 86_400))
    }

    private func commit() {
        items = history.items
        if ClipboardSettings.persist { store.save(items) }
        store.removeImages(except: Set(items.compactMap { $0.image?.fileName }))
    }

    private func applyOptions(previous: ClipboardOptions?) {
        monitor.readsImagesAndFiles = options.savesImagesAndFiles
        if previous?.pastesPlainText != options.pastesPlainText {
            if options.pastesPlainText { KeyboardShortcuts.enable([.pastePlainText]) } else { KeyboardShortcuts.disable([.pastePlainText]) }
        }
        guard previous?.retentionDays != options.retentionDays else { return }
        pruneExpired()
        commit()
    }

    private func observeClearEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, KeyPath<ClipboardAutoClear, Bool>)] = [
            (workspace, NSWorkspace.willSleepNotification, \.onSleep),
            (workspace, NSWorkspace.screensDidSleepNotification, \.onDisplaySleep),
            (distributed, Self.screenLocked, \.onLock),
        ]
        observers = events.map { center, name, rule in
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.options.autoClear[keyPath: rule] else { return }
                    self.clearPasteboard()
                }
            }
            return (center, token)
        }
    }

    private func clearIfDue() {
        guard options.autoClear.isDue(lastChange: monitor.lastChangeDate, now: Date()) else { return }
        clearPasteboard()
    }

    private func clearPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.pasteboardItems?.isEmpty == false else { return }
        pasteboard.clearContents()
    }

    private func refuse() -> Bool {
        NSSound.beep()
        return false
    }
}

struct PasteboardBackup {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }, uniquingKeysWith: { first, _ in first })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        let restored = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            values.forEach { item.setData($1, forType: $0) }
            return item
        }
        restored.first?.setData(Data(), forType: .init(PasteboardFacts.transient))
        pasteboard.clearContents()
        pasteboard.writeObjects(restored)
    }
}
