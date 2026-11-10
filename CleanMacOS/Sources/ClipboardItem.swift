import Foundation

struct ClipboardItem: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case text, image, files
    }

    struct ImageInfo: Codable, Hashable {
        let fileName: String
        let hash: String
        let width: Int
        let height: Int
    }

    static let previewLength = 120

    let id: UUID
    var text: String
    var createdAt: Date
    var kind: Kind
    var isPinned: Bool
    var sourceApp: String?
    var image: ImageInfo?
    var files: [String]

    init(id: UUID = UUID(), text: String, createdAt: Date = Date(), kind: Kind = .text, isPinned: Bool = false,
         sourceApp: String? = nil, image: ImageInfo? = nil, files: [String] = []) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.kind = kind
        self.isPinned = isPinned
        self.sourceApp = sourceApp
        self.image = image
        self.files = files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        image = try container.decodeIfPresent(ImageInfo.self, forKey: .image)
        files = try container.decodeIfPresent([String].self, forKey: .files) ?? []
    }

    var preview: String {
        switch kind {
        case .image:
            return "Image · \(image?.width ?? 0)×\(image?.height ?? 0)"
        case .files:
            return files.count == 1 ? URL(fileURLWithPath: files[0]).lastPathComponent : "\(files.count) files"
        case .text:
            let collapsed = text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard collapsed.count > Self.previewLength else { return collapsed }
            return String(collapsed.prefix(Self.previewLength)) + "…"
        }
    }

    func menuTitle(length: Int) -> String {
        let text = preview
        return text.count > length ? String(text.prefix(length)) + "…" : text
    }

    var searchText: String {
        switch kind {
        case .text: text
        case .image: preview
        case .files: files.joined(separator: " ")
        }
    }

    var dedupKey: String {
        switch kind {
        case .text: "text:" + text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .image: "image:" + (image?.hash ?? id.uuidString)
        case .files: "files:" + files.joined(separator: "\n")
        }
    }
}

struct ClipboardHistory: Equatable {
    private(set) var items: [ClipboardItem]

    init(items: [ClipboardItem] = []) {
        self.items = items.filter(\.isPinned) + items.filter { !$0.isPinned }
    }

    mutating func add(_ text: String, maxItems: Int) {
        insert(ClipboardItem(text: text), maxItems: maxItems)
    }

    mutating func insert(_ item: ClipboardItem, maxItems: Int) {
        var entry = item
        if let index = items.firstIndex(where: { $0.dedupKey == item.dedupKey }) {
            entry = items.remove(at: index)
            entry.createdAt = item.createdAt
            entry.sourceApp = item.sourceApp ?? entry.sourceApp
        }
        items.insert(entry, at: entry.isPinned ? 0 : items.prefix { $0.isPinned }.count)
        trim(to: maxItems)
    }

    mutating func togglePin(id: ClipboardItem.ID, at date: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.isPinned.toggle()
        if !item.isPinned { item.createdAt = date }
        items.insert(item, at: item.isPinned ? 0 : items.prefix { $0.isPinned }.count)
    }

    func neighbor(of id: ClipboardItem.ID, direction: Int, query: String = "") -> Int? {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              abs(direction) == 1, let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let next = index + direction
        guard items.indices.contains(next), items[next].isPinned == items[index].isPinned else { return nil }
        return next
    }

    @discardableResult
    mutating func move(_ id: ClipboardItem.ID, direction: Int, query: String = "") -> Bool {
        guard let next = neighbor(of: id, direction: direction, query: query),
              let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.swapAt(index, next)
        return true
    }

    mutating func recordUse(_ ids: [ClipboardItem.ID], at date: Date) {
        let used = ids.compactMap { id in items.first { $0.id == id } }.filter { !$0.isPinned }
        let selected = Set(ids)
        items.removeAll { selected.contains($0.id) && !$0.isPinned }
        items.insert(contentsOf: used, at: items.prefix { $0.isPinned }.count)
        for index in items.indices where selected.contains(items[index].id) { items[index].createdAt = date }
    }

    mutating func update(id: ClipboardItem.ID, text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .text else { return }
        items[index].text = text
    }

    mutating func prune(before cutoff: Date) {
        items.removeAll { !$0.isPinned && $0.createdAt < cutoff }
    }

    mutating func remove(id: ClipboardItem.ID) {
        items.removeAll { $0.id == id }
    }

    mutating func remove(ids: Set<ClipboardItem.ID>) {
        items.removeAll { ids.contains($0.id) }
    }

    mutating func clear() {
        items.removeAll { !$0.isPinned }
    }

    private mutating func trim(to maxItems: Int) {
        var unpinned = 0
        items = items.filter { item in
            guard !item.isPinned else { return true }
            unpinned += 1
            return unpinned <= maxItems
        }
    }
}
