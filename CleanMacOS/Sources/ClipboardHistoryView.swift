import SwiftUI

struct ClipboardHistoryView: View {
    @EnvironmentObject var clipboard: ClipboardViewModel
    @State private var search = ""
    @State private var showClearConfirm = false

    private var filtered: [ClipboardItem] {
        guard !search.isEmpty else { return clipboard.items }
        return clipboard.items.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if clipboard.items.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Clear clipboard history?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { clipboard.clearAll() }
        } message: {
            Text("This removes all \(clipboard.items.count) items and cannot be undone.")
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipboard History").font(.title2).fontWeight(.bold)
                    Text("\(clipboard.items.count) items — text only (images & files coming soon)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label("Clear All", systemImage: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(clipboard.items.isEmpty)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.caption)
                TextField("Search clipboard...", text: $search)
                    .textFieldStyle(.plain).font(.callout)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.caption)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        }
        .padding(16)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.on.clipboard").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text("No clipboard history yet").font(.headline)
            Text("Copy some text and it will show up here.\nImages and files are coming soon.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                HStack {
                    Text("NAME").frame(maxWidth: .infinity, alignment: .leading)
                    Text("DATE").frame(width: 140, alignment: .leading)
                    Text("ACTIONS").frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 24).padding(.vertical, 6)

                ForEach(filtered) { item in
                    ClipboardRow(item: item,
                                 onCopy: { clipboard.copy(item) },
                                 onDelete: { clipboard.delete(item) })
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack {
            Text(item.preview)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            HStack(spacing: 10) {
                Button { onCopy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
                Button { onDelete() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(.red).help("Delete")
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Color.gray.opacity(0.1) : .clear))
        .padding(.horizontal, 8)
        .onHover { hovered = $0 }
    }
}
