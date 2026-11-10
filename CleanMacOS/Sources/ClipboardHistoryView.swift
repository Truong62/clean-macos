import SwiftUI

struct ClipboardHistoryView: View {
    @EnvironmentObject var clipboard: ClipboardViewModel
    @State private var search = ""
    @State private var showClearConfirm = false
    @State private var showsLinkCleaner = false
    @State private var editing: ClipboardItem?

    private var sections: [(title: String?, items: [ClipboardItem])] {
        guard search.trimmingCharacters(in: .whitespaces).isEmpty else { return [(nil, ClipboardSearch.rank(clipboard.items, query: search))] }
        return [("PINNED", clipboard.pinnedItems), ("RECENT", clipboard.recentItems)].filter { !$0.items.isEmpty }
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            if clipboard.items.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background)
        .alert("Clear unpinned items?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { clipboard.clearAll() }
        } message: {
            Text("This removes \(clipboard.recentItems.count) items and cannot be undone. Pinned items stay.")
        }
        .sheet(item: $editing) { item in
            ClipboardEditSheet(text: item.text) { clipboard.update(item, text: $0) }
        }
    }

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack {
                Spacer()
                appPastelGradient
                    .frame(height: 320)
                    .blur(radius: 90)
                    .opacity(0.35)
            }
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(appPastelGradient)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    )
                    .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clipboard History").font(.title2).fontWeight(.bold)
                    Text("\(clipboard.pinnedItems.count) pinned · \(clipboard.recentItems.count) recent · text, images and files")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                capsuleButton("Clean a Link", icon: "link", tint: .accentColor) { showsLinkCleaner = true }
                    .popover(isPresented: $showsLinkCleaner, arrowEdge: .bottom) { LinkCleanerField() }
                capsuleButton("Clear Unpinned", icon: "trash", tint: .red) { showClearConfirm = true }
                    .disabled(clipboard.recentItems.isEmpty)
                    .opacity(clipboard.recentItems.isEmpty ? 0.5 : 1)
            }
            searchField
        }
        .padding(18)
        .glassCard(cornerRadius: 22)
    }

    private func capsuleButton(_ title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout).fontWeight(.medium)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .foregroundStyle(tint)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.callout)
            TextField("Search clipboard...", text: $search)
                .textFieldStyle(.plain).font(.callout)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.callout)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            RoundedRectangle(cornerRadius: 22)
                .fill(appPastelGradient)
                .frame(width: 88, height: 88)
                .overlay(
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                )
                .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
            Text("No clipboard history yet").font(.title3).fontWeight(.semibold)
            Text("Copy text, images or files and they show up here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .glassCard(cornerRadius: 22)
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CONTENT").frame(maxWidth: .infinity, alignment: .leading)
                Text("DATE").frame(width: 140, alignment: .leading)
                Text("ACTIONS").frame(width: 150, alignment: .trailing)
            }
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.tertiary).tracking(1)
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sections, id: \.title) { section in
                        if let title = section.title {
                            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(1).padding(.leading, 16).padding(.top, 4)
                        }
                        ForEach(section.items) { item in
                            ClipboardRow(item: item,
                                         onCopy: { clipboard.copy(item) },
                                         onPin: { clipboard.togglePin(item) },
                                         onEdit: item.kind == .text ? { editing = item } : clipboard.imageURL(for: item).map { url in { ScreenshotEditorBridge.open(url) } },
                                         onDelete: { clipboard.delete(item) })
                        }
                    }
                }
                .padding(2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: 22)
    }
}

struct ClipboardItemIcon: View {
    @EnvironmentObject var clipboard: ClipboardViewModel
    let item: ClipboardItem
    var size: CGFloat = 32

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let thumbnail = clipboard.thumbnail(for: item) {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo")
                }
            case .files:
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.files.first ?? "/")).resizable().scaledToFit()
            case .text:
                if let color = ColorText.parse(item.text) {
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: color.color))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
                } else {
                    Image(systemName: item.isPinned ? "pin.fill" : "text.alignleft").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onPin: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            ClipboardItemIcon(item: item)
            SourceAppBadge(item: item)
            Text(item.preview)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            HStack(spacing: 8) {
                roundButton(item.isPinned ? "pin.slash" : "pin", help: item.isPinned ? "Unpin" : "Pin", tint: .secondary, action: onPin)
                if let onEdit { roundButton("pencil", help: "Edit", tint: .secondary, action: onEdit) }
                roundButton("doc.on.doc", help: "Copy", tint: .secondary, action: onCopy)
                roundButton("trash", help: "Delete", tint: .red, action: onDelete)
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(hovered ? 0.12 : 0.04), radius: hovered ? 12 : 6, y: hovered ? 5 : 2)
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.2)) { hovered = isHovered }
        }
    }

    private func roundButton(_ icon: String, help: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain).help(help)
        .pointerCursor()
    }
}

struct ClipboardEditSheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(text: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Item").font(.headline)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minWidth: 480, minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

struct SourceAppBadge: View {
    @EnvironmentObject var clipboard: ClipboardViewModel
    let item: ClipboardItem

    var body: some View {
        if clipboard.options.showsSourceIcons, let source = item.sourceApp, let icon = AppIconCache.image(for: source) {
            Image(nsImage: icon).resizable().frame(width: 16, height: 16).help(AppListEditor.name(for: source))
        }
    }
}

struct ClipboardMenu: View {
    static let recentCount = 8
    static let titleLength = 40

    @ObservedObject var clipboard: ClipboardViewModel

    var body: some View {
        Button("Open Clipboard History") { NotificationCenter.default.post(name: .toggleClipboardPanel, object: nil) }
        Divider()
        ForEach(clipboard.items.prefix(Self.recentCount)) { item in
            Button(item.menuTitle(length: Self.titleLength)) { clipboard.copy(item) }
        }
        Divider()
        Button("Hide Latest Copy From Menu Bar") { clipboard.options.showsLatestInMenuBar = false }
    }
}

struct ClipboardMenuCard: View {
    static let recentCount = 3

    @ObservedObject var clipboard: ClipboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Clipboard", systemImage: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open History") { NotificationCenter.default.post(name: .toggleClipboardPanel, object: nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            ForEach(clipboard.items.prefix(Self.recentCount)) { item in
                Button { clipboard.copy(item) } label: {
                    HStack(spacing: 8) {
                        ClipboardItemIcon(item: item, size: 18)
                        Text(item.preview).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        if item.id == clipboard.currentItemID {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .environmentObject(clipboard)
    }
}
