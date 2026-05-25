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

    /// Deletes root-owned (sudo) items in one batch via an admin-authorized shell script.
    /// The app is unsigned, so a privileged helper isn't an option; macOS shows a single
    /// password prompt and runs `rm -rf` as root. Paths are shell-quoted to prevent injection,
    /// re-checked afterwards for accurate per-item results, and still gated by `isSafeToDelete`.
    func deletePrivileged(_ artifacts: [Artifact]) -> CleanResult {
        var deleted: [DeleteResult] = []
        var failCount = 0
        var safe: [Artifact] = []

        for artifact in artifacts {
            if ScannerService.isSafeToDelete(path: artifact.path) {
                safe.append(artifact)
            } else {
                deleted.append(DeleteResult(path: artifact.path, name: artifact.name, size: 0,
                                            success: false, error: "Path is not safe to delete"))
                failCount += 1
            }
        }

        guard !safe.isEmpty else {
            return CleanResult(deleted: deleted, totalFreed: 0, failCount: failCount, okCount: 0)
        }

        let script = "#!/bin/sh\n"
            + safe.map { "/bin/rm -rf \(Self.shellQuote($0.path))" }.joined(separator: "\n")
            + "\n"
        let scriptPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cleanmacos-\(UUID().uuidString).sh")

        guard (try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil else {
            for a in safe {
                deleted.append(DeleteResult(path: a.path, name: a.name, size: 0, success: false, error: "Could not stage delete script"))
                failCount += 1
            }
            return CleanResult(deleted: deleted, totalFreed: 0, failCount: failCount, okCount: 0)
        }
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        // One admin prompt for the whole batch.
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", "do shell script \"/bin/sh '\(scriptPath)'\" with administrator privileges"]
        let errPipe = Pipe()
        osa.standardOutput = Pipe()
        osa.standardError = errPipe

        var runError: String?
        do {
            try osa.run()
            osa.waitUntilExit()
            if osa.terminationStatus != 0 {
                let data = errPipe.fileHandleForReading.readDataToEndOfFile()
                runError = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            runError = error.localizedDescription
        }

        // Source of truth: did the path actually disappear?
        let fm = FileManager.default
        var totalFreed: Int64 = 0
        var okCount = 0
        for a in safe {
            if !fm.fileExists(atPath: a.path) {
                deleted.append(DeleteResult(path: a.path, name: a.name, size: a.size, success: true, error: nil))
                totalFreed += a.size
                okCount += 1
            } else {
                deleted.append(DeleteResult(path: a.path, name: a.name, size: a.size, success: false,
                                            error: runError ?? "Not deleted (authorization cancelled?)"))
                failCount += 1
            }
        }

        return CleanResult(deleted: deleted, totalFreed: totalFreed, failCount: failCount, okCount: okCount)
    }

    /// Wraps a path in single quotes, escaping embedded single quotes, for safe shell use.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
