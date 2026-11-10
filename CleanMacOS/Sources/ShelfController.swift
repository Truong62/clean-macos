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
    static let size = NSSize(width: 304, height: 280)
    static let dropZoneSize = NSSize(width: 240, height: 46)
    static let idleClose: TimeInterval = 5
    static let tickTime: TimeInterval = 0.9
    static let pointerGap: CGFloat = 16
    static let accepted: Set<NSPasteboard.PasteboardType> = Set([.fileURL, .URL, .string, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.init("com.apple.pasteboard.promised-file-url"), .init("com.apple.pasteboard.promised-file-content-type")])
    static let dropTypes: [UTType] = [.fileURL, .url, .image, .plainText] + NSFilePromiseReceiver.readableDraggedTypes.map { UTType(importedAs: $0) }

    @Published var settings: ShelfSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            apply(previous: oldValue)
        }
    }
    @Published private(set) var shelf: ShelfCollection {
        didSet { persist() }
    }
    @Published var expanded: Set<UUID> = []
    @Published private(set) var lastAdded: UUID?
    var internalDragIDs: Set<UUID> = []
    var openInIsland: (() -> Void)?
    var isHostedInIsland = false {
        didSet { if isHostedInIsland { close(); hideDropZone() } }
    }
    private var peekEdge: ShelfEdge?
    private var dwell = ShelfEdgeDwell()
    private var dragTimer: Timer?
    private var releaseWork: DispatchWorkItem?
    @Published var selection = ShelfSelection()
    @Published var isPinnedOpen = false
    @Published var isHovered = false {
        didSet { scheduleIdleClose() }
    }
    @Published private(set) var isOpen = false
    @Published private(set) var dropZone = DropZoneState.hidden

    private var dropGeneration = UUID()
    private var promiseBatches: [UUID: ShelfPromiseBatch] = [:]
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
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
    var visibleItems: [ShelfItem] { shelf.visible(expanded: expanded) }

    func toggleExpanded(_ item: ShelfItem) {
        promotePeek()
        if expanded.remove(item.id) == nil { expanded.insert(item.id) }
        selection.keep(visibleItems.map(\.id))
    }

    func promotePeek() {
        guard let edge = peekEdge, let panel else { return }
        releaseWork?.cancel()
        peekEdge = nil
        let point = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setFrame(edge.frame(at: point, size: panel.frame.size, peeking: false), display: true, animate: true)
        scheduleIdleClose()
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    func open() {
        if isHostedInIsland, let openInIsland { openInIsland(); return }
        if let panel {
            promotePeek()
            panel.orderFrontRegardless()
            return
        }
        hideDropZone()
        refreshMissingFiles()
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilitySubrole(.unknown)
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
        peekEdge = nil
        releaseWork?.cancel()
        if fromButton && settings.clearsOnClose { cancelPromises(); shelf.clear() }
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

    var canReceiveDrop: Bool { settings.isEnabled && shelf.freeSlots > 0 && internalDragIDs.isEmpty }

    private func cancelPromises() {
        dropGeneration = UUID()
        promiseBatches.values.forEach { $0.finish(accepted: false) }
        promiseBatches = [:]
    }

    private func showDropWarning(full: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = full ? "The Shelf is full" : "Some files could not be saved"
        alert.informativeText = full ? "The files arrived, but there is no room for this drop." : "Files that finished saving have been added."
        alert.addButton(withTitle: "OK")
        if let window = panel ?? zonePanel { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func accept(_ pasteboard: NSPasteboard, target: UUID? = nil) -> Bool {
        guard canReceiveDrop else { return false }
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        let entries = pasteboard.pasteboardItems ?? []
        var companions: [(Int, ShelfItem)] = []
        var receiverPositions: [Int] = []
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        for (index, entry) in entries.enumerated() {
            if !promiseTypes.isDisjoint(with: entry.types) { receiverPositions.append(index); continue }
            if let value = entry.string(forType: .fileURL), let url = URL(string: value) {
                companions.append((index, Self.fileItem(url)))
            } else if let data = entry.data(forType: .png) ?? entry.data(forType: .tiff), let item = Self.imageItem(from: data, store: store) {
                companions.append((index, item))
            } else if let value = entry.string(forType: .URL) {
                companions.append((index, ShelfItem(kind: .link, link: value)))
            } else if let value = entry.string(forType: .string), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                companions.append((index, ShelfItem(kind: .text, text: String(value.prefix(ShelfItem.maxText)))))
            }
        }
        guard receivers.count <= shelf.freeSlots,
              ShelfPromisePlan.accepts(receiverNames: receivers.map(\.fileNames), companions: companions.count, freeSlots: shelf.freeSlots) else { return false }
        guard !receivers.isEmpty else {
            guard !companions.isEmpty else { return false }
            promotePeek()
            add(companions.map(\.1), target: target)
            return true
        }
        let batch = ShelfPromiseBatch(target: target)
        promiseBatches[batch.id] = batch
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MacKitPromises", isDirectory: true).appendingPathComponent(batch.id.uuidString)
        do { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { promiseBatches[batch.id] = nil; return false }
        batch.setLanding(temporary)
        promotePeek()
        if zonePanel != nil { showDropZone(.added(receivers.count + companions.count)) }
        var advertised = receivers.map(\.fileNames)
        var remaining = advertised.reduce(0) { $0 + max(1, $1.count) }
        var results: [(Int, Int, ShelfItem)] = companions.map { ($0.0, 0, $0.1) }
        var failed = false
        let store = self.store
        for (index, receiver) in receivers.enumerated() {
            let position = receiverPositions.indices.contains(index) ? receiverPositions[index] : entries.count + index
            let landing = temporary.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: landing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            receiver.receivePromisedFiles(atDestination: landing, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                var copied: URL?
                if !batch.isCancelled, error == nil, ShelfPromisePlan.isSafe(url, inside: landing) {
                    if let saved = store.copyPromise(url, fallback: store.fallbackFolder) {
                        if batch.keep(saved.owner) { copied = saved.file } else { try? FileManager.default.removeItem(at: saved.owner) }
                    }
                }
                let saved = copied
                DispatchQueue.main.async {
                    guard let self else { batch.finish(accepted: false); return }
                    if let saved { results.append((position, advertised[index].firstIndex(of: url.lastPathComponent) ?? 0, Self.fileItem(saved))) }
                    else { failed = true }
                    remaining -= 1
                    guard remaining == 0 else { return }
                    defer {
                        self.promiseBatches[batch.id] = nil
                        try? FileManager.default.removeItem(at: temporary)
                    }
                    guard !batch.isCancelled, self.settings.isEnabled,
                          target == nil || self.shelf.allItems.contains(where: { $0.id == target }) else { batch.finish(accepted: false); return }
                    let ordered = results.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.2)
                    guard ordered.count <= self.shelf.freeSlots else {
                        batch.finish(accepted: false)
                        self.showDropWarning(full: true)
                        return
                    }
                    self.add(ordered, target: target)
                    batch.finish(accepted: true)
                    if failed { self.showDropWarning(full: false) }
                }
            }
            let names = receiver.fileNames
            remaining += max(1, names.count) - max(1, advertised[index].count)
            advertised[index] = names
            if !ShelfPromisePlan.accepts(receiverNames: advertised, companions: companions.count, freeSlots: shelf.freeSlots) {
                batch.finish(accepted: false)
                promiseBatches[batch.id] = nil
                return false
            }
        }
        return true
    }

    func accept(_ providers: [NSItemProvider], target: UUID? = nil) -> Bool {
        let pasteboard = NSPasteboard(name: .drag)
        if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) { return accept(pasteboard, target: target) }
        guard internalDragIDs.isEmpty, !providers.isEmpty, providers.count <= shelf.freeSlots else { return false }
        promotePeek()
        let generation = dropGeneration
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
            MainActor.assumeIsolated { guard generation == self.dropGeneration, self.settings.isEnabled, target == nil || self.shelf.allItems.contains(where: { $0.id == target }) else { return }
                self.add(loaded.sorted { $0.key < $1.key }.map(\.value), target: target) }
        }
        return !providers.isEmpty
    }

    func add(_ newItems: [ShelfItem], target: UUID? = nil) {
        let added = shelf.add(newItems, grouped: settings.groupsDrops, target: target)
        if let id = added.last {
            lastAdded = shelf.items.first { $0.allItems.contains { $0.id == id } && !expanded.contains($0.id) }?.id ?? id
        }
        guard !added.isEmpty else { return }
        if zonePanel != nil { showDropZone(.added(added.count)) }
        scheduleIdleClose()
    }

    func remove(_ ids: Set<ShelfItem.ID>) {
        let removed = Set(shelf.allItems.filter { ids.contains($0.id) }.flatMap(\.allItems).map(\.id))
        for batch in promiseBatches.values where batch.target.map(removed.contains) == true {
            batch.finish(accepted: false)
            promiseBatches[batch.id] = nil
        }
        shelf.remove(ids)
        selection.keep(visibleItems.map(\.id))
        scheduleIdleClose()
    }

    func removeSelectedOrAll() {
        if selection.ids.isEmpty { cancelPromises(); shelf.clear() } else { remove(selection.ids) }
        selection.clear()
    }

    func togglePin(_ item: ShelfItem) {
        shelf.togglePin(item.id)
    }

    func click(_ item: ShelfItem, modifiers: NSEvent.ModifierFlags) {
        promotePeek()
        selection.click(item.id, extend: modifiers.contains(.shift), order: visibleItems.map(\.id))
    }

    func dragged(_ item: ShelfItem) -> [ShelfItem] {
        let targets = selection.ids.contains(item.id) ? visibleItems.filter { selection.ids.contains($0.id) } : [item]
        var seen: Set<UUID> = []
        let protected = Set(shelf.allItems.filter(\.isPinned).flatMap(\.leaves).map(\.id))
        return targets.flatMap(\.leaves).filter { seen.insert($0.id).inserted }.map {
            var leaf = $0
            leaf.isPinned = leaf.isPinned || protected.contains(leaf.id)
            return leaf
        }
    }

    func didDragOut(_ dragged: [ShelfItem]) {
        if settings.closesAfterDrop && !isPinnedOpen { close() }
        guard settings.removesAfterDragOut else { return }
        shelf.removeAfterDragOut(Set(dragged.map(\.id)))
        selection.keep(visibleItems.map(\.id))
        scheduleIdleClose()
    }

    func allowsMove(_ dragged: [ShelfItem]) -> Bool {
        settings.removesAfterDragOut && dragged.allSatisfy { !$0.isPinned && !Self.isInsidePackage($0.fileURL) && $0.fileURL != nil }
    }

    private static func isInsidePackage(_ url: URL?) -> Bool {
        guard let url else { return false }
        var parent = url.resolvingSymlinksInPath().deletingLastPathComponent()
        while parent.path != "/" {
            if (try? parent.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return true }
            parent.deleteLastPathComponent()
        }
        return false
    }

    func mergeInternal(into target: UUID) -> Bool {
        guard settings.groupsDrops, !internalDragIDs.isEmpty else { return false }
        let dragged = shelf.leaves.filter { internalDragIDs.contains($0.id) }
        return !shelf.add(dragged, grouped: true, target: target, moving: internalDragIDs).isEmpty
    }

    func open(_ item: ShelfItem) {
        promotePeek()
        if item.isPile { toggleExpanded(item); return }
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
        return Array(common.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(40))
    }

    func thumbnail(for item: ShelfItem) -> NSImage? {
        let item = item.leaves.first ?? item
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
        Set(shelf.leaves.compactMap(\.path))
    }

    private func persist() {
        guard canSave else { return }
        store.save(shelf.items)
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
            guard let self, self.promiseBatches.isEmpty else { return }
            self.store.removePayloads(except: self.payloadPaths)
        }
    }

    private func apply(previous: ShelfSettings?) {
        if previous?.isEnabled != settings.isEnabled {
            if settings.isEnabled { KeyboardShortcuts.enable([.toggleShelf]) } else { KeyboardShortcuts.disable([.toggleShelf]) }
            if !settings.isEnabled { cancelPromises(); close() }
        }
        let watchesDrags = settings.isEnabled && (settings.opensOnShake || settings.showsDropZone || settings.peeksAtEdges)
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
                    let added = self.shelf.add(urls.map(Self.fileItem), grouped: self.settings.groupsDrops)
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
            dwell.reset()
            dragTimer?.invalidate()
            releaseWork?.cancel()
        case .leftMouseDragged:
            if !isContentDrag {
                guard dragPasteboard.changeCount != dragChangeCount,
                      !Self.accepted.isDisjoint(with: dragPasteboard.types ?? []), !isExcludedAppActive, internalDragIDs.isEmpty, !isHostedInIsland else { return }
                isContentDrag = true
                dragTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pollDrag() }
                }
                if settings.showsDropZone && !isOpen { showDropZone(.waiting) }
            }
            pollDrag()
            if settings.opensOnShake, !isOpen, shake.add(x: NSEvent.mouseLocation.x, at: event.timestamp) { open() }
        case .leftMouseUp:
            finishDrag()
            if dropZone == .waiting { settleDropZone() }
        default:
            break
        }
    }

    private func pollDrag() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { finishDrag(); return }
        guard settings.isEnabled, settings.peeksAtEdges, isContentDrag, !isHostedInIsland else { return }
        let point = NSEvent.mouseLocation
        if let edge = peekEdge {
            if edge.isTooFar(point) { close() }
            return
        }
        guard !isOpen else { return }
        let candidate = ShelfEdge.candidate(at: point, screens: NSScreen.screens.map { ($0.frame, $0.visibleFrame) })
        if let edge = dwell.update(candidate, at: ProcessInfo.processInfo.systemUptime) {
            open()
            peekEdge = edge
            idleWork?.cancel()
            panel?.setFrame(edge.frame(at: point, size: Self.size, peeking: true), display: true)
        }
    }

    private func finishDrag() {
        isContentDrag = false
        dwell.reset()
        dragTimer?.invalidate()
        dragTimer = nil
        if peekEdge != nil {
            let work = DispatchWorkItem { [weak self] in
                if self?.peekEdge != nil { self?.close() }
            }
            releaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        if dropZone == .waiting { settleDropZone() }
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
        guard settings.isEnabled, settings.showsDropZone, !isHostedInIsland, !isOpen, !shelf.items.isEmpty else { return hideDropZone() }
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
        case (0, true): selection.selectAll(visibleItems.map(\.id))
        case (53, _): if selection.ids.isEmpty { close() } else { selection.clear() }
        case (51, _): if !selection.ids.isEmpty { removeSelectedOrAll() }
        default: return false
        }
        return true
    }

    private func scheduleIdleClose() {
        idleWork?.cancel()
        guard isOpen, peekEdge == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shelf.items.isEmpty, !self.isPinnedOpen, !self.isHovered else { return }
            guard let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                MainActor.assumeIsolated {
                    guard let self, self.panel === panel, self.shelf.items.isEmpty, !self.isPinnedOpen, !self.isHovered else {
                        panel?.alphaValue = 1
                        return
                    }
                    self.close()
                }
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleClose, execute: work)
    }

    private func refreshMissingFiles() {
        var removed = 0
        for item in shelf.leaves where item.kind == .file {
            guard let path = item.path, !FileManager.default.fileExists(atPath: path) else { continue }
            var isStale = false
            if let bookmark = item.bookmark,
               let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale),
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
                completion(text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ShelfItem(kind: .text, text: String($0.prefix(ShelfItem.maxText))) })
            }
        } else {
            completion(nil)
        }
    }
}
