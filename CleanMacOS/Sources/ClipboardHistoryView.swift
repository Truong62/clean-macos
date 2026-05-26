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
        .alert("Clear clipboard history?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { clipboard.clearAll() }
        } message: {
            Text("This removes all \(clipboard.items.count) items and cannot be undone.")
        }
    }

    // Light base with a soft pastel glow pooling at the bottom (matches Home).
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
                    Text("\(clipboard.items.count) items — text only (images & files coming soon)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Label("Clear All", systemImage: "trash")
                        .font(.callout).fontWeight(.medium)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .foregroundStyle(.red)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(.red.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(clipboard.items.isEmpty)
                .opacity(clipboard.items.isEmpty ? 0.5 : 1)
            }

            searchField
        }
        .padding(18)
        .glassCard(cornerRadius: 22)
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
            Text("Copy some text and it will show up here.\nImages and files are coming soon.")
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
                Text("ACTIONS").frame(width: 90, alignment: .trailing)
            }
            .font(.caption2).fontWeight(.semibold)
            .foregroundStyle(.tertiary).tracking(1)
            .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { item in
                        ClipboardRow(item: item,
                                     onCopy: { clipboard.copy(item) },
                                     onDelete: { clipboard.delete(item) })
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

private struct ClipboardRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text(item.preview)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            HStack(spacing: 8) {
                Button { onCopy() } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain).help("Copy")
                .pointerCursor()
                Button { onDelete() } label: {
                    Image(systemName: "trash")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.ultraThinMaterial))
                        .overlay(Circle().strokeBorder(.red.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain).help("Delete")
                .pointerCursor()
            }
            .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(hovered ? 0.12 : 0.04),
                radius: hovered ? 12 : 6, y: hovered ? 5 : 2)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.2)) { hovered = h }
        }
    }
}
