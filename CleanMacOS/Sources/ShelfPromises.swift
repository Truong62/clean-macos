import AppKit
import SwiftUI

struct ShelfPromisePlan {
    static func accepts(receiverNames: [[String]], companions: Int, freeSlots: Int) -> Bool {
        companions + receiverNames.reduce(0) { $0 + max(1, $1.count) } <= freeSlots
    }

    static func isSafe(_ url: URL, inside folder: URL, fileManager: FileManager = .default) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/"),
              url.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/"),
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return false }
        if let entries = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let child as URL in entries {
                if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != false { return false }
            }
        }
        return true
    }
}

final class ShelfPromiseBatch: @unchecked Sendable {
    let id = UUID()
    let target: UUID?
    private let lock = NSLock()
    private var cancelled = false
    private var owned: [URL] = []
    private var landing: URL?

    init(target: UUID?) { self.target = target }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func setLanding(_ folder: URL) {
        lock.lock()
        landing = folder
        lock.unlock()
    }

    func keep(_ folder: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        owned.append(folder)
        return true
    }

    func finish(accepted: Bool) {
        lock.lock()
        if !accepted { cancelled = true }
        let folders = accepted && !cancelled ? [] : owned
        owned = []
        let temporary = cancelled ? landing : nil
        lock.unlock()
        if let temporary, UUID(uuidString: temporary.lastPathComponent) != nil { try? FileManager.default.removeItem(at: temporary) }
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

