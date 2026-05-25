import Foundation

struct LargeFile: Identifiable, Hashable, Sendable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
    let modified: Date

    var sizeHuman: String { formatBytes(size) }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: LargeFile, rhs: LargeFile) -> Bool { lhs.id == rhs.id }
}

/// Finds the biggest individual files under a folder — the "what's actually eating my disk" view.
final class LargeFilesService: Sendable {

    /// Largest regular files under `root` at or above `minBytes`, optionally only those whose
    /// modification date is at or before `olderThan`. Skips hidden files, symlinks and package
    /// internals. Time-bounded so a huge tree can't hang the scan.
    func scan(root: String,
              minBytes: Int64,
              olderThan: Date?,
              limit: Int = 300,
              timeout: TimeInterval = 60,
              excludeLibrary: Bool = true) -> [LargeFile] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: (root as NSString).standardizingPath)

        // node_modules holds huge numbers of small dependency files (covered by the Home tab) —
        // always skip it, it's the main thing that makes a home-folder scan crawl.
        let excludedNames: Set<String> = ["node_modules"]
        // ~/Library is huge and already covered by the Home tab — skip it by default for speed.
        let excludedDirs: Set<String> = excludeLibrary
            ? [fm.homeDirectoryForCurrentUser.appendingPathComponent("Library").path]
            : []

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let deadline = Date().addingTimeInterval(timeout)
        var found: [LargeFile] = []

        while let fileURL = enumerator.nextObject() as? URL {
            if Date() >= deadline { break }
            guard let v = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                if excludedDirs.contains(fileURL.path) || excludedNames.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard v.isRegularFile == true else { continue }

            let size = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            guard size >= minBytes else { continue }

            let modified = v.contentModificationDate ?? .distantPast
            if let olderThan, modified > olderThan { continue }

            found.append(LargeFile(path: fileURL.path, name: fileURL.lastPathComponent, size: size, modified: modified))
        }

        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }
}
