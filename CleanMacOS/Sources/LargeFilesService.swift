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

final class LargeFilesService: Sendable {
    static let excludedLibraryFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path

    func scan(root: String,
              minBytes: Int64,
              olderThan: Date?,
              limit: Int = 300,
              timeout: TimeInterval = 60,
              excludeLibrary: Bool = true) -> [LargeFile] {
        let folder = (root as NSString).standardizingPath
        return RustCore.largeFiles(root: folder, minBytes: minBytes, olderThan: olderThan, limit: limit, timeout: timeout,
                                   excludedFolder: excludeLibrary ? Self.excludedLibraryFolder : nil)
            .map { LargeFile(path: $0.path, name: ($0.path as NSString).lastPathComponent, size: $0.bytes,
                             modified: Date(timeIntervalSince1970: TimeInterval($0.modified))) }
    }
}
