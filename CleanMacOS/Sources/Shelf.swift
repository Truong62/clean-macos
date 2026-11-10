import Foundation

struct ShakeDetector {
    static let window: TimeInterval = 0.5
    static let reversals = 3
    static let travel: CGFloat = 220
    static let minLeg: CGFloat = 40
    static let cooldown: TimeInterval = 1

    private var samples: [(x: CGFloat, time: TimeInterval)] = []
    private var lastShake = -TimeInterval.infinity

    mutating func add(x: CGFloat, at time: TimeInterval) -> Bool {
        samples.append((x, time))
        samples.removeAll { time - $0.time > Self.window }
        guard time - lastShake >= Self.cooldown else { return false }
        let legs = Self.merge(zip(samples, samples.dropFirst()).map { $1.x - $0.x }.filter { $0 != 0 })
        let reversals = max(0, Self.merge(legs.filter { abs($0) >= Self.minLeg }).count - 1)
        let travel = legs.reduce(0) { $0 + abs($1) }
        guard reversals >= Self.reversals, travel > Self.travel else { return false }
        lastShake = time
        samples.removeAll()
        return true
    }

    mutating func reset() {
        samples.removeAll()
    }

    private static func merge(_ moves: [CGFloat]) -> [CGFloat] {
        var legs: [CGFloat] = []
        for move in moves {
            if let last = legs.last, (last > 0) == (move > 0) {
                legs[legs.count - 1] += move
            } else {
                legs.append(move)
            }
        }
        return legs
    }
}

struct ShelfItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case file, image, link, text
    }

    static let titleLength = 60
    static let maxText = 200_000

    var id = UUID()
    var kind: Kind
    var path: String?
    var bookmark: Data?
    var link: String?
    var text: String?
    var isPinned = false
    var addedAt = Date()

    var title: String {
        switch kind {
        case .file, .image:
            return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Item"
        case .link:
            return link.flatMap { URL(string: $0)?.host } ?? link ?? "Link"
        case .text:
            let lines = (text ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            return String((lines.first { !$0.isEmpty } ?? "").prefix(Self.titleLength))
        }
    }

    var fileURL: URL? {
        guard kind == .file || kind == .image, let path else { return nil }
        return URL(fileURLWithPath: path)
    }

    var dedupKey: String {
        "\(kind.rawValue):\(path ?? link ?? text ?? id.uuidString)"
    }
}

struct ShelfCollection: Equatable {
    static let limit = 200

    private(set) var items: [ShelfItem]

    init(items: [ShelfItem] = []) {
        self.items = items
    }

    @discardableResult
    mutating func add(_ newItems: [ShelfItem]) -> [ShelfItem.ID] {
        var added: [ShelfItem.ID] = []
        for item in newItems where !items.contains(where: { $0.dedupKey == item.dedupKey }) {
            items.append(item)
            added.append(item.id)
        }
        while items.count > Self.limit, let index = items.firstIndex(where: { !$0.isPinned }) {
            items.remove(at: index)
        }
        return added.filter { id in items.contains { $0.id == id } }
    }

    mutating func remove(_ ids: Set<ShelfItem.ID>) {
        items.removeAll { ids.contains($0.id) }
    }

    mutating func removeAfterDragOut(_ ids: Set<ShelfItem.ID>) {
        items.removeAll { ids.contains($0.id) && !$0.isPinned }
    }

    mutating func clear() {
        items.removeAll { !$0.isPinned }
    }

    mutating func togglePin(_ id: ShelfItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
    }

    mutating func update(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }
}

struct ShelfSelection: Equatable {
    private(set) var ids: Set<ShelfItem.ID> = []
    private var anchor: ShelfItem.ID?

    mutating func click(_ id: ShelfItem.ID, extend: Bool, order: [ShelfItem.ID]) {
        if extend, let anchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
            ids.formUnion(order[min(start, end)...max(start, end)])
            return
        }
        if ids.remove(id) == nil { ids.insert(id) }
        anchor = id
    }

    mutating func selectAll(_ order: [ShelfItem.ID]) {
        ids = Set(order)
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    mutating func keep(_ existing: [ShelfItem.ID]) {
        ids.formIntersection(existing)
    }
}

struct ShelfSettings: Codable, Equatable {
    var isEnabled = false
    var addsFinderSelection = false
    var opensOnShake = true
    var showsDropZone = true
    var closesAfterDrop = false
    var removesAfterDragOut = true
    var clearsOnClose = false
    var excludedApps: [String] = []
}

struct ShelfStore: @unchecked Sendable {
    static let key = "shelf.items"
    static let folderPermissions = 0o700

    let defaults: UserDefaults
    let payloadFolder: URL

    init(defaults: UserDefaults = .standard, payloadFolder: URL? = nil) {
        self.defaults = defaults
        self.payloadFolder = payloadFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanMacOS/Shelf", isDirectory: true)
    }

    func load() -> [ShelfItem]? {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return try? JSONDecoder().decode([ShelfItem].self, from: data)
    }

    func save(_ items: [ShelfItem]) {
        defaults.set(try? JSONEncoder().encode(items), forKey: Self.key)
    }

    func savePayload(_ data: Data, named name: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: payloadFolder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: Self.folderPermissions])
            let target = FileMove.destination(for: URL(fileURLWithPath: "/").appendingPathComponent(name), in: payloadFolder,
                                              exists: { FileManager.default.fileExists(atPath: $0.path) })
                ?? payloadFolder.appendingPathComponent(name)
            try data.write(to: target, options: .withoutOverwriting)
            return target
        } catch {
            NSLog("ShelfStore.savePayload failed for \(name): \(error.localizedDescription)")
            return nil
        }
    }

    func removePayloads(except paths: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: payloadFolder.path)) ?? []
        for file in files where !paths.contains(payloadFolder.appendingPathComponent(file).path) {
            try? FileManager.default.removeItem(at: payloadFolder.appendingPathComponent(file))
        }
    }
}
