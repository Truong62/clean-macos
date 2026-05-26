import Foundation

/// A single captured clipboard entry. Text-only for now.
struct ClipboardItem: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }

    /// Single-line, length-capped preview for the table's Name column.
    var preview: String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLen = 120
        guard collapsed.count > maxLen else { return collapsed }
        return String(collapsed.prefix(maxLen)) + "…"
    }
}

/// Pure, UI-free history transformations — easy to unit test.
struct ClipboardHistory: Equatable {
    private(set) var items: [ClipboardItem]

    init(items: [ClipboardItem] = []) {
        self.items = items
    }

    /// Insert `text` at the top. If an item with identical text already exists,
    /// move it to the top instead of duplicating. Trim oldest beyond `maxItems`.
    mutating func add(_ text: String, maxItems: Int) {
        items.removeAll { $0.text == text }
        items.insert(ClipboardItem(text: text), at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
    }

    mutating func remove(id: ClipboardItem.ID) {
        items.removeAll { $0.id == id }
    }

    mutating func clear() {
        items.removeAll()
    }
}
