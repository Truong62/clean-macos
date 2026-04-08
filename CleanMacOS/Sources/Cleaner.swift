import Foundation

final class CleanerService: Sendable {

    func deletePaths(_ paths: [String]) -> CleanResult {
        var deleted: [DeleteResult] = []
        var totalFreed: Int64 = 0
        var failCount = 0
        var okCount = 0

        for path in paths {
            let name = (path as NSString).lastPathComponent

            guard ScannerService.isSafeToDelete(path: path) else {
                deleted.append(DeleteResult(path: path, name: name, size: 0, success: false, error: "Path is not safe to delete"))
                failCount += 1
                continue
            }

            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                deleted.append(DeleteResult(path: path, name: name, size: 0, success: false, error: "Path does not exist"))
                failCount += 1
                continue
            }

            let size: Int64
            if isDir.boolValue {
                size = ScannerService.calculateDirSize(path: path)
            } else {
                size = ScannerService.physicalSize(path: path)
            }

            do {
                try fm.removeItem(atPath: path)
                deleted.append(DeleteResult(path: path, name: name, size: size, success: true, error: nil))
                totalFreed += size
                okCount += 1
            } catch {
                deleted.append(DeleteResult(path: path, name: name, size: size, success: false, error: "Delete failed: \(error.localizedDescription)"))
                failCount += 1
            }
        }

        return CleanResult(deleted: deleted, totalFreed: totalFreed, failCount: failCount, okCount: okCount)
    }
}
