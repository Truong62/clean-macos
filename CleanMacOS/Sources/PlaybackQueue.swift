import Foundation

enum RepeatMode: String, CaseIterable, Sendable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

struct PlaybackQueue: Equatable {
    private(set) var tracks: [Track] = []
    private(set) var order: [Int] = []
    private(set) var position: Int?
    private(set) var isShuffled = false
    var repeatMode: RepeatMode = .off

    init() {}

    init(tracks: [Track], startAt index: Int, shuffled: Bool = false, repeatMode: RepeatMode = .off,
         shuffle: ([Int]) -> [Int] = { $0.shuffled() }) {
        self.repeatMode = repeatMode
        isShuffled = shuffled
        guard tracks.indices.contains(index) else { return }
        self.tracks = tracks
        order = Array(tracks.indices)
        position = index
        if shuffled { setShuffled(true, shuffle: shuffle) }
    }

    var current: Track? { position.map { tracks[order[$0]] } }

    var upcoming: [Track] {
        guard let position else { return [] }
        return order[(position + 1)...].map { tracks[$0] }
    }

    func peekNext() -> Track? {
        nextPosition(automatic: true).map { tracks[order[$0]] }
    }

    mutating func advance(automatic: Bool) -> Track? {
        guard let next = nextPosition(automatic: automatic) else { return nil }
        position = next
        return current
    }

    mutating func retreat() -> Track? {
        guard let position else { return nil }
        if position > 0 {
            self.position = position - 1
        } else if repeatMode == .all {
            self.position = order.count - 1
        }
        return current
    }

    mutating func setShuffled(_ on: Bool, shuffle: ([Int]) -> [Int] = { $0.shuffled() }) {
        isShuffled = on
        guard let position else { return }
        let playing = order[position]
        order = on ? [playing] + shuffle(order.filter { $0 != playing }) : order.sorted()
        self.position = order.firstIndex(of: playing)
    }

    mutating func playNext(_ new: [Track]) {
        guard let position else { return append(new) }
        let start = tracks.count
        tracks += new
        order.insert(contentsOf: start..<tracks.count, at: position + 1)
    }

    mutating func append(_ new: [Track]) {
        let start = tracks.count
        tracks += new
        order += start..<tracks.count
        if position == nil, !order.isEmpty { position = 0 }
    }

    mutating func removeUpcoming(at offset: Int) {
        guard let position, order.indices.contains(position + 1 + offset) else { return }
        order.remove(at: position + 1 + offset)
    }

    mutating func jump(toUpcoming offset: Int) -> Track? {
        guard let position, order.indices.contains(position + 1 + offset) else { return nil }
        self.position = position + 1 + offset
        return current
    }

    private func nextPosition(automatic: Bool) -> Int? {
        guard let position else { return nil }
        if automatic && repeatMode == .one { return position }
        if position + 1 < order.count { return position + 1 }
        return repeatMode == .off ? nil : 0
    }
}
