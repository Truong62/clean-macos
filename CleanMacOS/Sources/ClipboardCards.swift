import AppKit
import SwiftUI

enum ClipboardCardGeometry {
    static func frame(in visible: CGRect) -> CGRect {
        CGRect(x: visible.minX + 16, y: visible.minY + 8, width: max(0, visible.width - 32), height: max(0, min(318, visible.height - 16)))
    }

    static func text(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\t", with: " ")
        return String(normalized.prefix(2000)) + (normalized.count > 2000 ? "…" : "")
    }
}

struct ClipboardMoveActions: View {
    @ObservedObject var clipboard: ClipboardViewModel
    let item: ClipboardItem
    var search = ""

    var body: some View {
        Button("Move Up") { clipboard.move(item, direction: -1, query: search) }
            .disabled(!clipboard.canMove(item, direction: -1, query: search))
        Button("Move Down") { clipboard.move(item, direction: 1, query: search) }
            .disabled(!clipboard.canMove(item, direction: 1, query: search))
    }
}

struct ClipboardHistoryCard: View {
    let item: ClipboardItem
    let index: Int
    @ObservedObject var model: ClipboardPanelModel
    @ObservedObject var clipboard: ClipboardViewModel
    @State private var hovered = false
    @State private var hoverTask: Task<Void, Never>?

    private var piled: Bool { model.state.pile.contains(item.id) }
    private var highlighted: Bool { model.highlightedID == item.id }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { model.state.togglePile(item.id) } label: {
                    if hovered || piled {
                        Image(systemName: piled ? "checkmark.circle.fill" : "circle")
                    } else if let source = item.sourceApp, let icon = AppIconCache.image(for: source) {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    } else {
                        ClipboardItemIcon(item: item, size: 18)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 25)
                if let source = item.sourceApp, NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) != nil {
                    Text(AppListEditor.name(for: source)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if hovered {
                    if let url = clipboard.imageURL(for: item) {
                        Button { ScreenshotEditorBridge.open(url) } label: { Image(systemName: "pencil") }
                            .help("Edit image")
                    }
                    Button { model.onCopy?([item]) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
                    Menu { actions } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .frame(height: 34)
            content.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            HStack {
                Text(item.createdAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                Spacer()
                if index < 9 { Text("⌘\(index + 1)").monospaced() }
            }
            .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 26)
        }
        .frame(width: 184, height: 210)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(piled ? 0.13 : highlighted ? 0.09 : hovered ? 0.055 : 0)).allowsHitTesting(false))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(piled || highlighted ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: piled || highlighted ? 2.5 : 0.5).allowsHitTesting(false))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { model.click(item, at: index) }
        .contextMenu { actions }
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.1)) { hovered = inside }
            hoverTask?.cancel()
            if inside && model.showsPreview && model.navigationPointer != NSEvent.mouseLocation {
                model.navigationPointer = nil
                hoverTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    model.highlightedID = item.id
                }
            }
        }
        .onDisappear { hoverTask?.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            VStack(alignment: .leading, spacing: 6) {
                if let color = ColorText.parse(item.text) { Circle().fill(Color(nsColor: color.color)).frame(width: 14, height: 14) }
                Text(highlightedText).font(.system(size: 12)).lineLimit(7)
            }
        case .image:
            VStack(alignment: .leading, spacing: 6) {
                if let image = clipboard.thumbnail(for: item) { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6)) }
                Text(item.preview).font(.caption)
            }
        case .files:
            VStack(alignment: .leading, spacing: 6) {
                if item.files.count == 1, let path = item.files.first {
                    FileThumbnail(path: path, side: 90)
                } else { ClipboardItemIcon(item: item, size: 40) }
                Text(item.preview).font(.system(size: 12, weight: .medium)).lineLimit(2)
                if item.files.count > 1 {
                    ForEach(Array(item.files.prefix(5).enumerated()), id: \.offset) { _, path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption2).lineLimit(1)
                    }
                }
            }
        }
    }

    private var highlightedText: AttributedString {
        let text = ClipboardCardGeometry.text(item.text)
        var result = AttributedString(text)
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return result }
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: result), let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].foregroundColor = .accentColor
            }
            start = range.upperBound
        }
        return result
    }

    @ViewBuilder private var actions: some View {
        Button("Paste") { model.onPaste?([item]) }
        Button("Copy") { model.onCopy?([item]) }
        Button(item.isPinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
        ClipboardMoveActions(clipboard: clipboard, item: item, search: model.search)
        Divider()
        Button("Delete", role: .destructive) { clipboard.delete(item) }
    }
}
