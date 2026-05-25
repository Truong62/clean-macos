import Foundation

final class CleanerService: Sendable {

    /// Reclaims space for the given artifacts, dispatching on each one's strategy:
    /// path deletion via FileManager, or running a command (e.g. `docker system prune`).
    func reclaim(_ artifacts: [Artifact]) -> CleanResult {
        var deleted: [DeleteResult] = []
        var totalFreed: Int64 = 0
        var failCount = 0
        var okCount = 0

        for artifact in artifacts {
            let result: DeleteResult
            switch artifact.reclaim {
            case .deletePath:
                result = deletePath(artifact)
            case let .command(tool, args):
                result = runCommand(artifact, tool: tool, args: args)
            }

            deleted.append(result)
            if result.success {
                totalFreed += result.size
                okCount += 1
            } else {
                failCount += 1
            }
        }

        return CleanResult(deleted: deleted, totalFreed: totalFreed, failCount: failCount, okCount: okCount)
    }

    /// Moves the given paths to the Trash (reversible). Used by the app uninstaller.
    func moveToTrash(_ paths: [String]) -> CleanResult {
        var deleted: [DeleteResult] = []
        var totalFreed: Int64 = 0
        var failCount = 0
        var okCount = 0
        let fm = FileManager.default

        for path in paths {
            let name = (path as NSString).lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                deleted.append(DeleteResult(path: path, name: name, size: 0, success: false, error: "Path does not exist"))
                failCount += 1
                continue
            }

            let size = isDir.boolValue
                ? ScannerService.calculateDirSize(path: path)
                : ScannerService.physicalSize(path: path)

            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                deleted.append(DeleteResult(path: path, name: name, size: size, success: true, error: nil))
                totalFreed += size
                okCount += 1
            } catch {
                deleted.append(DeleteResult(path: path, name: name, size: size, success: false, error: error.localizedDescription))
                failCount += 1
            }
        }

        return CleanResult(deleted: deleted, totalFreed: totalFreed, failCount: failCount, okCount: okCount)
    }

    // MARK: - Strategies

    private func deletePath(_ artifact: Artifact) -> DeleteResult {
        let path = artifact.path
        let name = (path as NSString).lastPathComponent

        guard ScannerService.isSafeToDelete(path: path) else {
            return DeleteResult(path: path, name: name, size: 0, success: false, error: "Path is not safe to delete")
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return DeleteResult(path: path, name: name, size: 0, success: false, error: "Path does not exist")
        }

        let size = isDir.boolValue
            ? ScannerService.calculateDirSize(path: path)
            : ScannerService.physicalSize(path: path)

        do {
            try fm.removeItem(atPath: path)
            return DeleteResult(path: path, name: name, size: size, success: true, error: nil)
        } catch {
            return DeleteResult(path: path, name: name, size: size, success: false, error: "Delete failed: \(error.localizedDescription)")
        }
    }

    private func runCommand(_ artifact: Artifact, tool: String, args: [String]) -> DeleteResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return DeleteResult(path: artifact.path, name: artifact.name, size: 0, success: false,
                                error: "Failed to run \(tool): \(error.localizedDescription)")
        }

        if process.terminationStatus == 0 {
            // Freed bytes aren't reported by the command; use the scanned estimate.
            return DeleteResult(path: artifact.path, name: artifact.name, size: artifact.size, success: true, error: nil)
        } else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return DeleteResult(path: artifact.path, name: artifact.name, size: 0, success: false,
                                error: msg?.isEmpty == false ? msg! : "Command exited with code \(process.terminationStatus)")
        }
    }
}
