import AppKit
import SwiftUI

struct ShelfView: View {
    @ObservedObject var controller: ShelfController
    @State private var isTargeted = false
    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

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
        .onDrop(of: ShelfController.dropTypes, isTargeted: $isTargeted) { controller.accept($0) }
        .onHover { controller.isHovered = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill").foregroundStyle(.secondary)
            Text(controller.selection.ids.isEmpty ? "Shelf" : "\(controller.selection.ids.count) selected").font(.headline)
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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(controller.items) { ShelfTile(item: $0, controller: controller) }
                }
                .padding(10)
            }
        }
    }

    private var footer: some View {
        let targets = controller.selection.ids.isEmpty ? controller.items : controller.items.filter { controller.selection.ids.contains($0.id) }
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
    static let size = CGSize(width: 84, height: 88)
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
        .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.25) : .clear))
        .overlay(alignment: .topLeading) {
            if item.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange).padding(4) }
        }
        .overlay(ShelfDragSource(item: item, controller: controller))
        .help(item.path ?? item.link ?? item.text.map { String($0.prefix(200)) } ?? item.title)
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .file:
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.path ?? "/")).resizable().scaledToFit()
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

struct ShelfDragSource: NSViewRepresentable {
    let item: ShelfItem
    let controller: ShelfController

    func makeNSView(context: Context) -> ShelfDragView {
        ShelfDragView()
    }

    func updateNSView(_ view: ShelfDragView, context: Context) {
        view.item = item
        view.controller = controller
    }
}

final class ShelfDragView: NSView, NSDraggingSource {
    static let dragThreshold: CGFloat = 3
    static let iconSize = NSSize(width: 48, height: 48)

    var item: ShelfItem?
    weak var controller: ShelfController?
    private var downEvent: NSEvent?
    private var draggedItems: [ShelfItem] = []

    override func mouseDown(with event: NSEvent) {
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
        beginDraggingSession(with: entries, event: event, source: self)
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
        context == .outsideApplication && controller?.allowsMove(draggedItems) == true ? [.copy, .move] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { draggedItems = [] }
        guard !operation.isEmpty else { return }
        controller?.didDragOut(draggedItems)
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
        .onDrop(of: ShelfController.dropTypes, isTargeted: $isTargeted) { controller.accept($0) }
        .onTapGesture { controller.open() }
    }
}
