import SwiftUI

/// Searchable, keyboard-navigable list shown in the floating hotkey panel.
struct ClipboardPanelView: View {
    @ObservedObject var clipboard: ClipboardViewModel
    let onSelect: (ClipboardItem) -> Void
    let onCancel: () -> Void

    @State private var search = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var filtered: [ClipboardItem] {
        guard !search.isEmpty else { return clipboard.items }
        return clipboard.items.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clipboard…", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { commit() }
            }
            .padding(12)
            Divider()
            if filtered.isEmpty {
                VStack { Spacer(); Text("No items").foregroundStyle(.secondary); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                                HStack {
                                    Text(item.preview).lineLimit(2)
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(index == selection ? Color.accentColor.opacity(0.25) : .clear))
                                .contentShape(Rectangle())
                                .id(index)
                                .onTapGesture { selection = index; commit() }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selection) { _, new in
                        withAnimation { proxy.scrollTo(new, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: 480, height: 420)
        .onAppear {
            selection = 0
            // Defer focus until the panel is key, otherwise it doesn't take.
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: search) { _, _ in selection = 0 }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        selection = max(0, min(filtered.count - 1, selection + delta))
    }

    private func commit() {
        guard filtered.indices.contains(selection) else { return }
        onSelect(filtered[selection])
    }
}
