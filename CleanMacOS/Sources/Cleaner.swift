import Foundation
import Darwin

final class CleanerService: Sendable {
    func reclaim(_ artifacts: [Artifact]) -> CleanResult {
        var deleted: [DeleteResult] = []
        var retryArtifacts: [Artifact] = []

        for artifact in artifacts {
            switch artifact.reclaim {
            case .deletePath:
                let (result, retry) = deletePath(artifact)
                deleted.append(result)
                retryArtifacts.append(contentsOf: retry)
            case let .command(tool, args):
                deleted.append(runCommand(artifact, tool: tool, args: args))
            }
        }

        let uniqueRetries = Dictionary(grouping: retryArtifacts, by: \.path).compactMap(\.value.first)
        return CleanResult(
            deleted: deleted,
            totalFreed: deleted.reduce(0) { $0 + $1.freedBytes },
            failCount: deleted.filter { !$0.success }.count,
            okCount: deleted.filter(\.success).count,
            retryArtifacts: uniqueRetries
        )
    }

    func moveToTrash(_ paths: [String]) -> CleanResult {
        var deleted: [DeleteResult] = []
        let fm = FileManager.default

        for path in paths {
            let name = (path as NSString).lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
                deleted.append(DeleteResult(path: path, name: name, size: 0, success: false, error: "Path does not exist"))
                continue
            }

            let size = isDir.boolValue
                ? ScannerService.calculateDirSize(path: path, timeout: 120)
                : ScannerService.physicalSize(path: path)

            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                deleted.append(DeleteResult(path: path, name: name, size: size, success: true, error: nil))
            } catch {
                deleted.append(DeleteResult(
                    path: path,
                    name: name,
                    size: size,
                    success: false,
                    error: Self.errorText(error),
                    retryableAsAdmin: Self.isRetryablePermissionError(error)
                ))
            }
        }

        return CleanResult(
            deleted: deleted,
            totalFreed: deleted.reduce(0) { $0 + $1.freedBytes },
            failCount: deleted.filter { !$0.success }.count,
            okCount: deleted.filter(\.success).count
        )
    }

    func deletePrivileged(_ artifacts: [Artifact]) -> CleanResult {
        var deleted: [DeleteResult] = []
        var safe: [Artifact] = []

        for artifact in artifacts {
            guard ScannerService.isSafeToDelete(path: artifact.path) else {
                deleted.append(DeleteResult(
                    path: artifact.path,
                    name: artifact.name,
                    size: artifact.size,
                    success: false,
                    error: "Path is not safe to delete"
                ))
                continue
            }
            safe.append(artifact)
        }

        guard !safe.isEmpty else {
            return CleanResult(deleted: deleted, totalFreed: 0, failCount: deleted.count, okCount: 0)
        }

        let beforeSizes = Dictionary(uniqueKeysWithValues: safe.map { artifact in
            (artifact.path, currentSize(at: artifact.path))
        })
        let script = "#!/bin/sh\n"
            + safe.map { "/bin/rm -rf \(Self.shellQuote($0.path))" }.joined(separator: "\n")
            + "\n"
        let scriptPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cleanmacos-\(UUID().uuidString).sh")

        guard (try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)) != nil else {
            for artifact in safe {
                deleted.append(DeleteResult(
                    path: artifact.path,
                    name: artifact.name,
                    size: artifact.size,
                    success: false,
                    error: "Could not stage delete script"
                ))
            }
            return CleanResult(deleted: deleted, totalFreed: 0, failCount: deleted.count, okCount: 0)
        }
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

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
            runError = Self.errorText(error)
        }

        for artifact in safe {
            let before = beforeSizes[artifact.path] ?? artifact.size
            let after = currentSize(at: artifact.path)
            let freed = max(0, before - after)
            if !Self.pathExists(artifact.path) {
                deleted.append(DeleteResult(
                    path: artifact.path,
                    name: artifact.name,
                    size: artifact.size,
                    freedBytes: freed,
                    success: true,
                    error: nil
                ))
            } else {
                deleted.append(DeleteResult(
                    path: artifact.path,
                    name: artifact.name,
                    size: artifact.size,
                    freedBytes: freed,
                    success: false,
                    error: runError?.isEmpty == false ? runError : "Not deleted (authorization cancelled?)"
                ))
            }
        }

        return CleanResult(
            deleted: deleted,
            totalFreed: deleted.reduce(0) { $0 + $1.freedBytes },
            failCount: deleted.filter { !$0.success }.count,
            okCount: deleted.filter(\.success).count
        )
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isRetryablePermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteNoPermissionError {
            return true
        }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else { return false }
        return isRetryablePermissionError(underlying)
    }

    private func deletePath(_ artifact: Artifact) -> (DeleteResult, [Artifact]) {
        let path = artifact.path
        guard ScannerService.isSafeToDelete(path: path) else {
            return (DeleteResult(
                path: path,
                name: artifact.name,
                size: artifact.size,
                success: false,
                error: "Path is not safe to delete"
            ), [])
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || Self.pathExists(path) else {
            return (DeleteResult(
                path: path,
                name: artifact.name,
                size: artifact.size,
                success: false,
                error: "Path does not exist"
            ), [])
        }

        guard isDirectory.boolValue else { return deleteFile(artifact) }
        return deleteDirectory(artifact)
    }

    private func deleteFile(_ artifact: Artifact) -> (DeleteResult, [Artifact]) {
        let size = currentSize(at: artifact.path)
        do {
            try FileManager.default.removeItem(atPath: artifact.path)
            return (DeleteResult(
                path: artifact.path,
                name: artifact.name,
                size: artifact.size,
                freedBytes: size,
                success: true,
                error: nil
            ), [])
        } catch {
            let retryable = Self.isRetryablePermissionError(error)
            let result = DeleteResult(
                path: artifact.path,
                name: artifact.name,
                size: artifact.size,
                success: false,
                error: Self.errorText(error),
                retryableAsAdmin: retryable
            )
            return (result, retryable ? [artifact] : [])
        }
    }

    private func deleteDirectory(_ artifact: Artifact) -> (DeleteResult, [Artifact]) {
        let fm = FileManager.default
        let childNames: [String]
        do {
            childNames = try fm.contentsOfDirectory(atPath: artifact.path)
        } catch {
            let retryable = Self.isRetryablePermissionError(error)
            return (DeleteResult(
                path: artifact.path,
                name: artifact.name,
                size: artifact.size,
                success: false,
                error: Self.errorText(error),
                retryableAsAdmin: retryable
            ), retryable ? [artifact] : [])
        }

        var freed: Int64 = 0
        var failures: [DeleteResult] = []
        var retryArtifacts: [Artifact] = []

        for childName in childNames {
            let childPath = (artifact.path as NSString).appendingPathComponent(childName)
            let before = currentSize(at: childPath)
            do {
                try fm.removeItem(atPath: childPath)
                freed += before
            } catch {
                let after = currentSize(at: childPath)
                let childFreed = max(0, before - after)
                let retryable = Self.isRetryablePermissionError(error)
                freed += childFreed
                failures.append(DeleteResult(
                    path: childPath,
                    name: childName,
                    size: before,
                    freedBytes: childFreed,
                    success: false,
                    error: Self.errorText(error),
                    retryableAsAdmin: retryable
                ))
                if retryable {
                    retryArtifacts.append(retryArtifact(path: childPath, size: after, parent: artifact))
                }
            }
        }

        let containerError: Error?
        if rmdir(artifact.path) == 0 {
            containerError = nil
        } else {
            containerError = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        if !Self.pathExists(artifact.path) {
            return (DeleteResult(
                path: artifact.path,
                name: artifact.name,
                size: artifact.size,
                freedBytes: freed,
                success: true,
                error: nil
            ), [])
        }

        if failures.isEmpty, let containerError {
            let retryable = Self.isRetryablePermissionError(containerError)
            if retryable { retryArtifacts.append(artifact) }
            return (DeleteResult(
                path: artifact.path,
                name: artifact.name,
                size: artifact.size,
                freedBytes: freed,
                success: false,
                error: Self.errorText(containerError),
                retryableAsAdmin: retryable
            ), retryArtifacts)
        }

        let error = failures
            .map { "\($0.path): \($0.error ?? "Delete failed")" }
            .joined(separator: "\n")
        return (DeleteResult(
            path: artifact.path,
            name: artifact.name,
            size: artifact.size,
            freedBytes: freed,
            success: false,
            error: error,
            retryableAsAdmin: failures.contains(where: \.retryableAsAdmin),
            failures: failures
        ), retryArtifacts)
    }

    private func retryArtifact(path: String, size: Int64, parent: Artifact) -> Artifact {
        Artifact(
            path: path,
            name: (path as NSString).lastPathComponent,
            size: size,
            category: parent.category,
            description: parent.description,
            needsSudo: true,
            isPersonalData: parent.isPersonalData
        )
    }

    private func currentSize(at path: String) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || Self.pathExists(path) else { return 0 }
        if isDirectory.boolValue {
            return ScannerService.calculateDirSize(path: path, timeout: 120)
        }
        return ScannerService.physicalSize(path: path)
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
            return DeleteResult(
                path: artifact.path,
                name: artifact.name,
                size: artifact.size,
                success: false,
                error: "Failed to run \(tool): \(Self.errorText(error))"
            )
        }

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return DeleteResult(
                path: artifact.path,
                name: artifact.name,
                size: artifact.size,
                success: false,
                error: message?.isEmpty == false ? message : "Command exited with code \(process.terminationStatus)"
            )
        }

        return DeleteResult(
            path: artifact.path,
            name: artifact.name,
            size: artifact.size,
            success: true,
            error: nil
        )
    }

    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func errorText(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return "\(nsError.localizedDescription) (errno \(nsError.code): \(String(cString: strerror(Int32(nsError.code)))))"
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return "\(nsError.localizedDescription) (errno \(underlying.code): \(String(cString: strerror(Int32(underlying.code)))))"
        }
        return nsError.localizedDescription
    }
}
