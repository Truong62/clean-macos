import AppKit
import SwiftUI

struct ShelfView: View {
    @ObservedObject var controller: ShelfController
    @State private var isTargeted = false
    private let columns = Array(repeating: GridItem(.fixed(78), spacing: 8), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: ShelfController.size.width, height: ShelfController.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2))
        .onDrop(of: ShelfController.accepted.map(\.rawValue), isTargeted: $isTargeted) { controller.accept($0) }
        .onHover { controller.isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill").foregroundStyle(.secondary)
            Text(controller.selection.ids.isEmpty ? "Shelf · \(controller.shelf.leaves.count)" : "\(controller.selection.ids.count) selected").font(.headline)
            Spacer()
            Button { controller.isPinnedOpen.toggle() } label: {
                Image(systemName: controller.isPinnedOpen ? "pin.fill" : "pin").foregroundStyle(controller.isPinnedOpen ? Color.orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Keep the Shelf open")
            Button { controller.close(fromButton: true) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.borderless)
                .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var content: some View {
        if controller.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("Drop files, images, links or text here").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(controller.visibleItems) { ShelfTile(item: $0, controller: controller).id($0.id) }
                    }
                    .padding(10)
                }
                .onChange(of: controller.lastAdded) { _, id in
                    if let id { withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private var footer: some View {
        let targets = (controller.selection.ids.isEmpty ? controller.items : controller.visibleItems.filter { controller.selection.ids.contains($0.id) }).flatMap(\.leaves)
        return HStack(spacing: 10) {
            Text("Drag items out to use them · ⌘A selects all").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button { controller.share(targets) } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.borderless)
                .disabled(targets.isEmpty)
                .help("Share or AirDrop")
            Button { controller.removeSelectedOrAll() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(controller.items.isEmpty)
                .help(controller.selection.ids.isEmpty ? "Clear the Shelf (pinned items stay)" : "Remove the selected items")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ShelfTile: View {
    static let size = CGSize(width: 78, height: 88)
    static let iconSize: CGFloat = 46

    let item: ShelfItem
    @ObservedObject var controller: ShelfController

    var body: some View {
        let isSelected = controller.selection.ids.contains(item.id)
        VStack(spacing: 4) {
            icon.frame(width: Self.iconSize, height: Self.iconSize)
            Text(item.title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
        }
        .padding(4)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.16) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .overlay(alignment: .topTrailing) {
            if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
        }
        .overlay(alignment: .topLeading) {
            if item.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange).padding(4) }
        }
        .overlay(ShelfDragSource(item: item, controller: controller))
        .overlay(alignment: .topLeading) {
            if item.isPile {
                Button { controller.toggleExpanded(item) } label: {
                    Image(systemName: controller.expanded.contains(item.id) ? "chevron.down" : "chevron.right")
                }.buttonStyle(.borderless).padding(4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if item.isPile { Text("\(item.leaves.count)").font(.caption2.bold()).padding(4).background(Color.accentColor, in: Capsule()) }
        }
        .help(item.path ?? item.link ?? item.text.map { String($0.prefix(200)) } ?? item.title)
    }

    @ViewBuilder private var icon: some View {
        let face = item.leaves.first ?? item
        if item.isPile {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)).offset(x: 6, y: -6)
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.2)).offset(x: 3, y: -3)
                if let path = face.path { FileThumbnail(path: path, side: Self.iconSize) }
                else { Image(systemName: face.kind == .link ? "link" : "text.alignleft").font(.system(size: 26)) }
            }
        } else {
        switch item.kind {
        case .file:
            FileThumbnail(path: item.path ?? "/", side: Self.iconSize)
        case .image:
            if let image = controller.thumbnail(for: item) {
                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(.secondary)
            }
        case .link:
            Image(systemName: "link").font(.system(size: 26)).foregroundStyle(.blue)
        case .text:
            Image(systemName: "text.alignleft").font(.system(size: 26)).foregroundStyle(.secondary)
        }
        }
    }
}

struct ShelfDragSource: NSViewRepresentable {
    let item: ShelfItem
    let controller: ShelfController

    func makeNSView(context: Context) -> ShelfDragView {
        ShelfDragView()
    }

    func updateNSView(_ view: ShelfDragView, context: Context) {
        view.item = item
        view.controller = controller
        view.registerForDraggedTypes(Array(ShelfController.accepted))
    }
}

final class ShelfDragView: NSView, NSDraggingSource {
    static let dragThreshold: CGFloat = 4
    static let iconSize = NSSize(width: 48, height: 48)

    var item: ShelfItem?
    weak var controller: ShelfController?
    private var downEvent: NSEvent?
    private var draggedItems: [ShelfItem] = []

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard controller?.settings.groupsDrops == true, let item,
              controller?.internalDragIDs.contains(item.id) != true else { return [] }
        return controller?.internalDragIDs.isEmpty == false ? .move : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let item, let controller, controller.settings.groupsDrops else { return false }
        if !controller.internalDragIDs.isEmpty {
            let accepted = controller.mergeInternal(into: item.id)
            if accepted { draggedItems = []; controller.internalDragIDs = [] }
            return accepted
        }
        return controller.accept(sender.draggingPasteboard, target: item.id)
    }

    override func mouseDown(with event: NSEvent) {
        controller?.promotePeek()
        downEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downEvent, let item, let controller else { return }
        let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
        guard distance > Self.dragThreshold else { return }
        downEvent = nil
        let dragged = controller.dragged(item)
        let entries = dragged.compactMap { entry -> NSDraggingItem? in
            guard let writer = ShelfController.pasteboardWriter(for: entry) else { return nil }
            let dragItem = NSDraggingItem(pasteboardWriter: writer)
            dragItem.setDraggingFrame(NSRect(origin: .zero, size: Self.iconSize), contents: Self.icon(for: entry, controller: controller))
            return dragItem
        }
        guard !entries.isEmpty else { return }
        draggedItems = dragged
        controller.internalDragIDs = Set(dragged.map(\.id))
        let session = beginDraggingSession(with: entries, event: event, source: self)
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        guard downEvent != nil, let item, let controller else { return }
        downEvent = nil
        if event.clickCount == 2 {
            controller.open(item)
        } else {
            controller.click(item, modifiers: event.modifierFlags)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let controller else { return nil }
        let targets = controller.dragged(item)
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(item.isPinned ? "Unpin" : "Pin") { controller.togglePin(item) })
        menu.addItem(ActionMenuItem("Open") { controller.open(item) })
        if let url = item.fileURL, item.kind == .image || ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(url.pathExtension.lowercased()) {
            menu.addItem(ActionMenuItem("Edit Image…") { ScreenshotEditorBridge.open(url) })
        }
        let apps = controller.commonApps(for: targets)
        if !apps.isEmpty {
            let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            apps.forEach { app in submenu.addItem(ActionMenuItem(FileManager.default.displayName(atPath: app.path)) { controller.open(targets, with: app) }) }
            openWith.submenu = submenu
            menu.addItem(openWith)
        }
        if targets.contains(where: { $0.fileURL != nil }) { menu.addItem(ActionMenuItem("Show in Finder") { controller.reveal(targets) }) }
        menu.addItem(ActionMenuItem("Share…") { controller.share(targets) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Remove") { controller.remove(Set(targets.map(\.id))) })
        return menu
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if context == .withinApplication { return .move }
        return controller?.allowsMove(draggedItems) == true ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { draggedItems = []; controller?.internalDragIDs = [] }
        guard !operation.isEmpty else { return }
        if controller?.internalDragIDs.isEmpty == false { controller?.didDragOut(draggedItems) }
    }

    private static func icon(for item: ShelfItem, controller: ShelfController) -> NSImage {
        if let thumbnail = controller.thumbnail(for: item) { return thumbnail }
        if let url = item.fileURL { return NSWorkspace.shared.icon(forFile: url.path) }
        let symbol = item.kind == .link ? "link" : "text.alignleft"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: item.title) ?? NSImage()
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

struct ShelfDropZone: View {
    @ObservedObject var controller: ShelfController
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            switch controller.dropZone {
            case .added(let count):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Added \(count) to the Shelf")
            case .holding(let count):
                Image(systemName: "tray.full.fill")
                Text("\(count) on the Shelf")
            default:
                Image(systemName: "tray.and.arrow.down.fill")
                Text("Drop on the Shelf")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .frame(width: ShelfController.dropZoneSize.width, height: ShelfController.dropZoneSize.height)
        .background(Capsule().fill(isTargeted ? Color.accentColor.opacity(0.35) : Color(nsColor: .windowBackgroundColor).opacity(0.94)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(isTargeted ? 1 : 0.4), lineWidth: 1.5))
        .contentShape(Capsule())
        .onDrop(of: ShelfController.accepted.map(\.rawValue), isTargeted: $isTargeted) { controller.accept($0) }
        .onTapGesture { controller.open() }
    }
}
