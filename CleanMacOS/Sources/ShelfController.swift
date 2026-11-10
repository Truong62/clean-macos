import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

enum DropZoneState: Equatable {
    case hidden, waiting, added(Int), holding(Int)
}

@MainActor
final class ShelfController: NSObject, ObservableObject, NSWindowDelegate {
    static let settingsKey = "shelf.settings"
    static let size = NSSize(width: 440, height: 300)
    static let dropZoneSize = NSSize(width: 240, height: 46)
    static let idleClose: TimeInterval = 5
    static let tickTime: TimeInterval = 0.9
    static let pointerGap: CGFloat = 24
    static let accepted: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL, .string, .png, .tiff]
    static let dropTypes: [UTType] = [.fileURL, .url, .image, .plainText]

    @Published var settings: ShelfSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            apply(previous: oldValue)
        }
    }
    @Published private(set) var shelf: ShelfCollection {
        didSet { persist() }
    }
    @Published var selection = ShelfSelection()
    @Published var isPinnedOpen = false
    @Published var isHovered = false {
        didSet { scheduleIdleClose() }
    }
    @Published private(set) var isOpen = false
    @Published private(set) var dropZone = DropZoneState.hidden

    private let store: ShelfStore
    private var canSave = true
    private var panel: NSPanel?
    private var zonePanel: NSPanel?
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var dragChangeCount = 0
    private var isContentDrag = false
    private var shake = ShakeDetector()
    private var idleWork: DispatchWorkItem?
    private let thumbnails = NSCache<NSString, NSImage>()
    private let hud = InputHUD()

    init(store: ShelfStore = ShelfStore()) {
        self.store = store
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(ShelfSettings.self, from: $0) }
            ?? ShelfSettings()
        let saved = store.load()
        canSave = saved != nil
        shelf = ShelfCollection(items: saved ?? [])
        super.init()
        KeyboardShortcuts.onKeyUp(for: .toggleShelf) { [weak self] in
            MainActor.assumeIsolated { self?.shortcutPressed() }
        }
        if canSave { store.removePayloads(except: payloadPaths) }
        apply(previous: nil)
    }

    var items: [ShelfItem] { shelf.items }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        hideDropZone()
        refreshMissingFiles()
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: ShelfView(controller: self))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(Self.size)
        panel.delegate = self
        panel.setFrameOrigin(Self.origin(below: NSEvent.mouseLocation, size: Self.size))
        panel.orderFrontRegardless()
        self.panel = panel
        isOpen = true
        installKeyMonitor()
        scheduleIdleClose()
    }

    func close(fromButton: Bool = false) {
        if fromButton && settings.clearsOnClose { shelf.clear() }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        idleWork?.cancel()
        let closing = panel
        panel = nil
        closing?.orderOut(nil)
        isOpen = false
        isPinnedOpen = false
        selection.clear()
        settleDropZone()
    }

    func accept(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var loaded: [Int: ShelfItem] = [:]
        for (index, provider) in providers.enumerated() {
            group.enter()
            Self.load(provider, store: store) { item in
                DispatchQueue.main.async {
                    if let item { loaded[index] = item }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { self.add(loaded.sorted { $0.key < $1.key }.map(\.value)) }
        }
        return !providers.isEmpty
    }

    func add(_ newItems: [ShelfItem]) {
        let added = shelf.add(newItems)
        guard !added.isEmpty else { return }
        if zonePanel != nil { showDropZone(.added(added.count)) }
        if isOpen && settings.closesAfterDrop && !isPinnedOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tickTime) { [weak self] in self?.close() }
        }
        scheduleIdleClose()
    }

    func remove(_ ids: Set<ShelfItem.ID>) {
        shelf.remove(ids)
        selection.keep(shelf.items.map(\.id))
        scheduleIdleClose()
    }

    func removeSelectedOrAll() {
        if selection.ids.isEmpty { shelf.clear() } else { remove(selection.ids) }
        selection.clear()
    }

    func togglePin(_ item: ShelfItem) {
        shelf.togglePin(item.id)
    }

    func click(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        selection.click(item.id, extend: modifiers.contains(.shift), order: shelf.items.map(\.id))
    }

    func dragged(_ item: ShelfItem) -> [ShelfItem] {
        selection.ids.contains(item.id) ? shelf.items.filter { selection.ids.contains($0.id) } : [item]
    }

    func didDragOut(_ dragged: [ShelfItem]) {
        guard settings.removesAfterDragOut else { return }
        shelf.removeAfterDragOut(Set(dragged.map(\.id)))
        selection.keep(shelf.items.map(\.id))
        scheduleIdleClose()
    }

    func allowsMove(_ dragged: [ShelfItem]) -> Bool {
        settings.removesAfterDragOut && dragged.allSatisfy { !$0.isPinned && !($0.path ?? "").contains(".app/") && $0.fileURL != nil }
    }

    func open(_ item: ShelfItem) {
        if let url = item.fileURL ?? item.link.flatMap(URL.init(string:)) {
            NSWorkspace.shared.open(url)
        } else if let text = item.text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hud.show("Copied the text", for: Self.tickTime)
        }
    }

    func open(_ items: [ShelfItem], with app: URL) {
        NSWorkspace.shared.open(items.compactMap(\.fileURL), withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func reveal(_ items: [ShelfItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.compactMap(\.fileURL))
    }

    func share(_ items: [ShelfItem]) {
        guard let view = panel?.contentView else { return }
        let picker = NSSharingServicePicker(items: items.map(Self.shareObject))
        picker.show(relativeTo: NSRect(x: 0, y: 0, width: view.bounds.width, height: 40), of: view, preferredEdge: .minY)
    }

    func commonApps(for items: [ShelfItem]) -> [URL] {
        let files = items.compactMap(\.fileURL)
        guard !files.isEmpty, files.count == items.count else { return [] }
        let lists = files.map { Set(NSWorkspace.shared.urlsForApplications(toOpen: $0)) }
        let common = lists.dropFirst().reduce(lists[0]) { $0.intersection($1) }
        return common.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func thumbnail(for item: ShelfItem) -> NSImage? {
        guard item.kind == .image, let path = item.path else { return nil }
        if let cached = thumbnails.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        thumbnails.setObject(image, forKey: path as NSString)
        return image
    }

    static func pasteboardWriter(for item: ShelfItem) -> NSPasteboardWriting? {
        if let url = item.fileURL { return url as NSURL }
        if let link = item.link.flatMap(URL.init(string:)) { return link as NSURL }
        return item.text.map { $0 as NSString }
    }

    func windowDidResignKey(_ notification: Notification) {
        selection.clear()
    }

    private static func shareObject(_ item: ShelfItem) -> Any {
        item.fileURL ?? item.link.flatMap(URL.init(string:)).map { $0 as Any } ?? (item.text ?? "") as Any
    }

    private var payloadPaths: Set<String> {
        Set(shelf.items.filter { $0.kind == .image }.compactMap(\.path))
    }

    private func persist() {
        guard canSave else { return }
        store.save(shelf.items)
        store.removePayloads(except: payloadPaths)
    }

    private func apply(previous: ShelfSettings?) {
        if previous?.isEnabled != settings.isEnabled {
            if settings.isEnabled { KeyboardShortcuts.enable([.toggleShelf]) } else { KeyboardShortcuts.disable([.toggleShelf]) }
            if !settings.isEnabled { close() }
        }
        let watchesDrags = settings.isEnabled && (settings.opensOnShake || settings.showsDropZone)
        if watchesDrags, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.watch(event) }
            }
        } else if !watchesDrags, let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
            hideDropZone()
        }
    }

    private func shortcutPressed() {
        guard settings.addsFinderSelection, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FinderTools.finderID else { return toggle() }
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = FinderScript.run(FinderScript.selection).map(FinderScript.urls) ?? []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let added = self.shelf.add(urls.map(Self.fileItem))
                    if added.isEmpty { self.toggle() } else { self.open() }
                }
            }
        }
    }

    private func watch(_ event: NSEvent) {
        let dragPasteboard = NSPasteboard(name: .drag)
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = dragPasteboard.changeCount
            isContentDrag = false
            shake.reset()
        case .leftMouseDragged:
            if !isContentDrag {
                guard dragPasteboard.changeCount != dragChangeCount,
                      !Self.accepted.isDisjoint(with: dragPasteboard.types ?? []), !isExcludedAppActive else { return }
                isContentDrag = true
                if settings.showsDropZone && !isOpen { showDropZone(.waiting) }
            }
            if settings.opensOnShake, !isOpen, shake.add(x: NSEvent.mouseLocation.x, at: event.timestamp) { open() }
        case .leftMouseUp:
            isContentDrag = false
            if dropZone == .waiting { settleDropZone() }
        default:
            break
        }
    }

    private var isExcludedAppActive: Bool {
        settings.excludedApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    private func showDropZone(_ state: DropZoneState) {
        dropZone = state
        if zonePanel == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.dropZoneSize), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let host = NSHostingController(rootView: ShelfDropZone(controller: self))
            host.sizingOptions = []
            panel.contentViewController = host
            panel.setContentSize(Self.dropZoneSize)
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: visible.midX - Self.dropZoneSize.width / 2, y: visible.maxY - Self.dropZoneSize.height - 8))
            }
            panel.orderFrontRegardless()
            zonePanel = panel
        }
        if case .added = state {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.tickTime) { [weak self] in
                guard let self, case .added = self.dropZone else { return }
                self.settleDropZone()
            }
        }
    }

    func settleDropZone() {
        guard settings.isEnabled, settings.showsDropZone, !isOpen, !shelf.items.isEmpty else { return hideDropZone() }
        showDropZone(.holding(shelf.items.count))
    }

    func hideDropZone() {
        zonePanel?.orderOut(nil)
        zonePanel = nil
        dropZone = .hidden
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let hasCommand = event.modifierFlags.contains(.command)
            let windowNumber = event.windowNumber
            let isHandled = MainActor.assumeIsolated {
                self?.handleKey(keyCode, hasCommand: hasCommand, windowNumber: windowNumber) ?? false
            }
            return isHandled ? nil : event
        }
    }

    private func handleKey(_ keyCode: UInt16, hasCommand: Bool, windowNumber: Int) -> Bool {
        guard let panel, panel.windowNumber == windowNumber else { return false }
        switch (keyCode, hasCommand) {
        case (0, true): selection.selectAll(shelf.items.map(\.id))
        case (53, _): if selection.ids.isEmpty { close() } else { selection.clear() }
        case (51, _): if !selection.ids.isEmpty { removeSelectedOrAll() }
        default: return false
        }
        return true
    }

    private func scheduleIdleClose() {
        idleWork?.cancel()
        guard isOpen else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shelf.items.isEmpty, !self.isPinnedOpen, !self.isHovered else { return }
            self.close()
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleClose, execute: work)
    }

    private func refreshMissingFiles() {
        var removed = 0
        for item in shelf.items where item.kind == .file {
            guard let path = item.path, !FileManager.default.fileExists(atPath: path) else { continue }
            var isStale = false
            if let bookmark = item.bookmark,
               let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale),
               FileManager.default.fileExists(atPath: url.path) {
                var moved = item
                moved.path = url.path
                moved.bookmark = isStale ? (try? url.bookmarkData()) ?? bookmark : bookmark
                shelf.update(moved)
            } else if Self.isOnMountedVolume(path) {
                shelf.remove([item.id])
                removed += 1
            }
        }
        if removed > 0 { hud.show("Removed \(removed) missing \(removed == 1 ? "file" : "files") from the Shelf", for: Self.tickTime * 2) }
    }

    private static func isOnMountedVolume(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard parts.first == "Volumes", parts.count > 1 else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/\(parts[1])")
    }

    private static func origin(below point: NSPoint, size: NSSize) -> NSPoint {
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height - pointerGap)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        }
        return origin
    }

    nonisolated private static func imageItem(from data: Data, store: ShelfStore) -> ShelfItem? {
        let bitmap = NSBitmapImageRep(data: data) ?? NSImage(data: data)?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        guard let png = bitmap?.representation(using: .png, properties: [:]),
              let saved = store.savePayload(png, named: PastedImage.fileName(at: Date(), prefix: "Shelf_Image")) else { return nil }
        return ShelfItem(kind: .image, path: saved.path)
    }

    nonisolated static func fileItem(_ url: URL) -> ShelfItem {
        ShelfItem(kind: .file, path: url.path, bookmark: try? url.bookmarkData())
    }

    nonisolated private static func load(_ provider: NSItemProvider, store: ShelfStore, completion: @escaping @Sendable (ShelfItem?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in completion(url.map(fileItem)) }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                completion(data.flatMap { imageItem(from: $0, store: store) })
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in completion(url.map { ShelfItem(kind: .link, link: $0.absoluteString) }) }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            _ = provider.loadObject(ofClass: String.self) { text, _ in
                completion(text.map { ShelfItem(kind: .text, text: String($0.prefix(ShelfItem.maxText))) })
            }
        } else {
            completion(nil)
        }
    }
}
