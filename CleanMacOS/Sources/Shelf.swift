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

    static let titleLength = 48
    static let maxText = 200_000

    var id = UUID()
    var kind: Kind
    var path: String?
    var bookmark: Data?
    var link: String?
    var text: String?
    var isPinned = false
    var addedAt = Date()
    var children: [ShelfItem]?

    var isPile: Bool { children != nil }
    var leaves: [ShelfItem] { children?.flatMap(\.leaves) ?? [self] }
    var allItems: [ShelfItem] { [self] + (children?.flatMap(\.allItems) ?? []) }

    var title: String {
        if let children { return (children.first?.title ?? "Pile") + " +\(max(0, leaves.count - 1))" }
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
        guard !isPile else { return nil }
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
    var leaves: [ShelfItem] { items.flatMap(\.leaves) }
    var allItems: [ShelfItem] { items.flatMap(\.allItems) }
    var freeSlots: Int { max(0, Self.limit - leaves.count) }

    init(items: [ShelfItem] = []) { self.items = items }

    func visible(expanded: Set<UUID>) -> [ShelfItem] {
        func visit(_ item: ShelfItem) -> [ShelfItem] {
            [item] + (expanded.contains(item.id) ? item.children?.flatMap(visit) ?? [] : [])
        }
        return items.flatMap(visit)
    }

    @discardableResult
    mutating func add(_ newItems: [ShelfItem], grouped: Bool = false, target: UUID? = nil, moving: Set<UUID> = []) -> [UUID] {
        if let target {
            guard let destination = allItems.first(where: { $0.id == target }), !moving.contains(target),
                  Set(destination.allItems.map(\.id)).isDisjoint(with: moving),
                  !allItems.filter({ moving.contains($0.id) }).contains(where: { $0.allItems.contains { $0.id == target } }) else { return [] }
        } else if !moving.isEmpty { return [] }
        let existing = Set(leaves.filter { !moving.contains($0.id) }.map(\.dedupKey))
        var seen = existing
        let incoming = newItems.flatMap(\.leaves).filter { seen.insert($0.dedupKey).inserted }
        guard !incoming.isEmpty, leaves.count - moving.count + incoming.count <= Self.limit else { return [] }
        if !moving.isEmpty { remove(moving) }
        if let target {
            transform(target) { item in
                var copy = item
                if copy.children == nil {
                    var child = item
                    child.id = UUID()
                    child.isPinned = false
                    copy.children = [child]
                }
                copy.children?.append(contentsOf: incoming)
                return copy
            }
            return [target]
        }
        if grouped && incoming.count > 1 {
            let pile = ShelfItem(kind: incoming[0].kind, children: incoming)
            items.append(pile)
            return [pile.id]
        }
        items.append(contentsOf: incoming)
        return incoming.map(\.id)
    }

    mutating func remove(_ ids: Set<UUID>) {
        items = items.compactMap { Self.removing($0, ids: ids, protectsPins: false) }
    }

    mutating func removeAfterDragOut(_ ids: Set<UUID>) {
        items = items.compactMap { Self.removing($0, ids: ids, protectsPins: true) }
    }

    private static func removing(_ item: ShelfItem, ids: Set<UUID>, protectsPins: Bool) -> ShelfItem? {
        if protectsPins && item.isPinned { return item }
        if ids.contains(item.id) && (!protectsPins || !item.isPile) { return nil }
        guard let children = item.children else { return item }
        var copy = item
        copy.children = children.compactMap { removing($0, ids: ids, protectsPins: protectsPins) }
        guard let remaining = copy.children, !remaining.isEmpty else { return nil }
        if remaining.count == 1 {
            var child = remaining[0]
            child.isPinned = child.isPinned || item.isPinned
            return child
        }
        return copy
    }

    mutating func clear() { removeAfterDragOut(Set(allItems.map(\.id))) }
    mutating func togglePin(_ id: UUID) { transform(id) { var item = $0; item.isPinned.toggle(); return item } }
    mutating func update(_ item: ShelfItem) { transform(item.id) { _ in item } }

    private mutating func transform(_ id: UUID, change: (ShelfItem) -> ShelfItem) {
        func visit(_ item: ShelfItem) -> ShelfItem {
            if item.id == id { return change(item) }
            var copy = item
            copy.children = item.children?.map(visit)
            return copy
        }
        items = items.map(visit)
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
    var peeksAtEdges = false
    var groupsDrops = false
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
    let fallbackFolder: URL

    init(defaults: UserDefaults = .standard, payloadFolder: URL? = nil) {
        self.defaults = defaults
        self.fallbackFolder = payloadFolder.map { $0.appendingPathComponent("Fallback", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MacKitShelfStore", isDirectory: true)
        self.payloadFolder = payloadFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanMacOS/Shelf", isDirectory: true)
    }

    func load() -> [ShelfItem]? {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        guard let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return nil }
        func limit(_ item: ShelfItem, depth: Int) -> ShelfItem {
            var copy = item
            if depth >= 3, item.isPile { copy.children = item.leaves }
            else { copy.children = item.children?.map { limit($0, depth: depth + 1) } }
            return copy
        }
        return decoded.map { limit($0, depth: 1) }
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

    func copyPromise(_ file: URL, fallback: URL) -> (file: URL, owner: URL)? {
        for root in [payloadFolder, fallback] {
            let owner = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: true, attributes: [.posixPermissions: Self.folderPermissions])
                let target = owner.appendingPathComponent(file.lastPathComponent)
                try FileManager.default.copyItem(at: file, to: target)
                return (target, owner)
            } catch { try? FileManager.default.removeItem(at: owner) }
        }
        return nil
    }

    func removePayloads(except paths: Set<String>) {
        for root in [payloadFolder, fallbackFolder] { removePayloads(in: root, except: paths) }
    }

    private func removePayloads(in root: URL, except paths: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for file in files {
            let url = root.appendingPathComponent(file)
            guard !paths.contains(where: { $0 == url.path || $0.hasPrefix(url.path + "/") }) else { continue }
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !directory || UUID(uuidString: file) != nil { try? FileManager.default.removeItem(at: url) }
        }
    }
}

extension ShelfSettings {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        addsFinderSelection = try values.decodeIfPresent(Bool.self, forKey: .addsFinderSelection) ?? defaults.addsFinderSelection
        peeksAtEdges = try values.decodeIfPresent(Bool.self, forKey: .peeksAtEdges) ?? defaults.peeksAtEdges
        groupsDrops = try values.decodeIfPresent(Bool.self, forKey: .groupsDrops) ?? defaults.groupsDrops
        opensOnShake = try values.decodeIfPresent(Bool.self, forKey: .opensOnShake) ?? defaults.opensOnShake
        showsDropZone = try values.decodeIfPresent(Bool.self, forKey: .showsDropZone) ?? defaults.showsDropZone
        closesAfterDrop = try values.decodeIfPresent(Bool.self, forKey: .closesAfterDrop) ?? defaults.closesAfterDrop
        removesAfterDragOut = try values.decodeIfPresent(Bool.self, forKey: .removesAfterDragOut) ?? defaults.removesAfterDragOut
        clearsOnClose = try values.decodeIfPresent(Bool.self, forKey: .clearsOnClose) ?? defaults.clearsOnClose
        excludedApps = try values.decodeIfPresent([String].self, forKey: .excludedApps) ?? defaults.excludedApps
    }
}
