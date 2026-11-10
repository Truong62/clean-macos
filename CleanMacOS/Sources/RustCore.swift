import CMacKitCore
import Foundation

enum RustCore {
    struct FoundFile: Decodable, Equatable {
        let path: String
        let bytes: Int64
        let modified: Int64
    }

    static func dirSize(path: String, timeout: TimeInterval, maxDepth: Int) -> (size: Int64, didTimeout: Bool) {
        var bytes: UInt64 = 0
        let didTimeout = mk_dir_size(path, milliseconds(timeout), UInt32(clamping: maxDepth), &bytes)
        return (Int64(clamping: bytes), didTimeout)
    }

    static func largeFiles(root: String, minBytes: Int64, olderThan: Date?, limit: Int, timeout: TimeInterval,
                           excludedFolder: String?) -> [FoundFile] {
        let cutoff = Int64(olderThan?.timeIntervalSince1970 ?? 0)
        guard let raw = mk_large_files_json(root, UInt64(clamping: max(0, minBytes)), cutoff, UInt32(clamping: limit),
                                            milliseconds(timeout), excludedFolder) else { return [] }
        defer { mk_string_free(raw) }
        return (try? JSONDecoder().decode([FoundFile].self, from: Data(bytes: raw, count: strlen(raw)))) ?? []
    }

    private static func milliseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1000)
    }
}
