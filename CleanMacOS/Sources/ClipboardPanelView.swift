import AppKit
import SwiftUI

@MainActor
final class ClipboardPanelModel: ObservableObject {
    static let previewKey = "clipboard.panel.showsPreview"

    @Published var search = "" {
        didSet { if search != oldValue { state.selection = 0 } }
    }
    @Published var state = ClipboardPanelState()
    @Published var showsPreview: Bool {
        didSet {
            UserDefaults.standard.set(showsPreview, forKey: Self.previewKey)
            onPreviewToggle?(showsPreview)
        }
    }

    let clipboard: ClipboardViewModel
    var onPaste: (([ClipboardItem]) -> Void)?
    var onCopy: (([ClipboardItem]) -> Void)?
    var onClose: (() -> Void)?
    var onPreviewToggle: ((Bool) -> Void)?

    init(clipboard: ClipboardViewModel) {
        self.clipboard = clipboard
        showsPreview = UserDefaults.standard.bool(forKey: Self.previewKey)
    }

    var sections: [(title: String?, items: [ClipboardItem])] {
        guard search.trimmingCharacters(in: .whitespaces).isEmpty else { return [(nil, ClipboardSearch.rank(clipboard.items, query: search))] }
        return [("PINNED", clipboard.pinnedItems), ("RECENT", clipboard.recentItems)].filter { !$0.items.isEmpty }
    }

    var visible: [ClipboardItem] { sections.flatMap(\.items) }
    var pile: [ClipboardItem] { state.pileItems(in: clipboard.items) }

    var selected: ClipboardItem? {
        let items = visible
        return items.indices.contains(state.selection) ? items[state.selection] : nil
    }

    func reset() {
        search = ""
        state = ClipboardPanelState()
    }

    func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let command = PanelKeys.command(keyCode: keyCode, modifiers: modifiers, usedArrows: state.usedArrows, hasPile: !state.pile.isEmpty) else {
            state.usedArrows = false
            return false
        }
        perform(command)
        return true
    }

    func perform(_ command: PanelCommand) {
        let items = visible
        let current = items.indices.contains(state.selection) ? items[state.selection] : nil
        let targets = pile.isEmpty ? current.map { [$0] } ?? [] : pile
        switch command {
        case .move(let delta):
            state.move(by: delta, count: items.count)
            state.usedArrows = true
        case .paste:
            if !targets.isEmpty { onPaste?(targets) }
        case .copyOnly:
            if !targets.isEmpty { onCopy?(targets) }
        case .togglePile:
            if let current { state.togglePile(current.id) }
        case .pasteNumber(let number):
            if items.indices.contains(number - 1) { onPaste?([items[number - 1]]) }
        case .togglePin:
            guard let current else { return }
            clipboard.togglePin(current)
            state.selection = visible.firstIndex { $0.id == current.id } ?? state.selection
        case .delete:
            guard let current else { return }
            state.pile.remove(current.id)
            clipboard.delete(current)
            state.move(by: 0, count: visible.count)
        case .deletePile:
            clipboard.delete(state.pile)
            state.pile = []
            state.move(by: 0, count: visible.count)
        case .togglePreview:
            showsPreview.toggle()
        case .escape:
            if state.pile.isEmpty { onClose?() } else { state.pile = [] }
        }
    }

    func click(_ item: ClipboardItem, at index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            state.togglePile(item.id)
        } else if flags.contains(.shift) {
            state.extendPile(through: index, in: visible)
        } else {
            state.selection = index
            onPaste?([item])
        }
    }
}

struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    @ObservedObject var clipboard: ClipboardViewModel
    @FocusState private var searchFocused: Bool
    @State private var confirmsClear = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                list
                Divider()
                footer
            }
            .frame(minWidth: ClipboardPanelController.size.width)
            if model.showsPreview {
                Divider()
                ClipboardPreviewPane(item: model.selected) { model.onCopy?([$0]) }
                    .frame(width: ClipboardPanelController.previewWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search clipboard…", text: $model.search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            Button { model.showsPreview.toggle() } label: {
                Image(systemName: "sidebar.right").foregroundStyle(model.showsPreview ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Preview")
            Button { model.onClose?() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.borderless)
                .help("Close (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var list: some View {
        let sections = model.sections
        let visible = sections.flatMap(\.items)
        let indexes = Dictionary(uniqueKeysWithValues: visible.enumerated().map { ($1.id, $0) })
        return Group {
            if visible.isEmpty {
                Text(clipboard.items.isEmpty ? "Nothing copied yet" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(sections, id: \.title) { section in
                                if let title = section.title {
                                    Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
                                        .padding(.horizontal, 10).padding(.top, 6)
                                }
                                ForEach(section.items) { item in
                                    row(item, index: indexes[item.id] ?? 0)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: model.state.selection) { _, selection in
                        guard visible.indices.contains(selection) else { return }
                        withAnimation { proxy.scrollTo(visible[selection].id, anchor: .center) }
                    }
                }
            }
        }
    }

    private func row(_ item: ClipboardItem, index: Int) -> some View {
        let isSelected = index == model.state.selection
        let isPiled = model.state.pile.contains(item.id)
        return HStack(spacing: 10) {
            if isPiled { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
            ClipboardItemIcon(item: item, size: 28)
            SourceAppBadge(item: item)
            Text(item.preview).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.createdAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                    .font(.caption2).foregroundStyle(.secondary)
                if index < PanelKeys.digitKeys.count {
                    Text("⌘\(index + 1)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Color.accentColor.opacity(0.22) : isPiled ? Color.accentColor.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .id(item.id)
        .onTapGesture { model.click(item, at: index) }
        .contextMenu {
            Button("Paste") { model.onPaste?([item]) }
            Button("Copy") { model.onCopy?([item]) }
            Button(item.isPinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
            Divider()
            Button("Delete", role: .destructive) { clipboard.delete(item) }
        }
    }

    private var footer: some View {
        let pile = model.pile
        return HStack(spacing: 12) {
            if !pile.isEmpty {
                Button("Paste \(pile.count)") { model.onPaste?(pile) }
                Button("Copy \(pile.count)") { model.onCopy?(pile) }
                Button("Delete \(pile.count)", role: .destructive) { model.perform(.deletePile) }
                Button("Clear Selection") { model.state.pile = [] }
            } else if confirmsClear {
                Text("Clear \(clipboard.recentItems.count) unpinned items?").font(.caption)
                Button("Clear", role: .destructive) {
                    clipboard.clearAll()
                    confirmsClear = false
                }
                Button("Cancel") { confirmsClear = false }
            } else {
                Button("Clear Unpinned") { confirmsClear = true }.disabled(clipboard.recentItems.isEmpty)
                Text("↩ paste · ⇧↩ copy · ⌘↩ select · ⌥P pin").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(clipboard.items.count) items").font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ClipboardPreviewPane: View {
    static let maxPreviewCharacters = 20_000
    static let maxJSONCharacters = 200_000

    @EnvironmentObject var clipboard: ClipboardViewModel
    let item: ClipboardItem?
    let onCopy: (ClipboardItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item {
                content(item)
                Spacer(minLength: 0)
                HStack {
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") { onCopy(item) }
                }
            } else {
                Text("Nothing selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .padding(.top, 8)
    }

    @ViewBuilder private func content(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(displayText(item.text))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image:
            if let url = clipboard.imageURL(for: item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
            }
            Text(item.preview).font(.caption).foregroundStyle(.secondary)
        case .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(item.files, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.callout).lineLimit(1)
                                Text(Self.details(path)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func displayText(_ text: String) -> String {
        let pretty = text.count <= Self.maxJSONCharacters ? PrettyJSON.format(text) : nil
        return String((pretty ?? text).prefix(Self.maxPreviewCharacters))
    }

    static func details(_ path: String) -> String {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return "Missing · " + path }
        guard !isFolder.boolValue, let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 else { return "Folder · " + path }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file) + " · " + path
    }
}

@MainActor
enum AppIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for bundleID: String) -> NSImage? {
        if let cached = cache.object(forKey: bundleID as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}
