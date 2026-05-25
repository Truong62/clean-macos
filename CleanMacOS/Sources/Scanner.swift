import Foundation

final class ScannerService: Sendable {

    // MARK: - Disk Info

    func getDiskInfo(path: String = "/") -> DiskInfo? {
        var stat = statfs()
        guard statfs(path, &stat) == 0 else { return nil }

        let blockSize = UInt64(stat.f_bsize)
        let total = stat.f_blocks * blockSize
        let free = UInt64(stat.f_bavail) * blockSize
        let used = total - free
        let usedPct = Double(used) / Double(total) * 100

        let hostname = ProcessInfo.processInfo.hostName
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif

        return DiskInfo(
            total: total, used: used, free: free,
            usedPercent: usedPct,
            hostname: hostname, osVersion: osVersion, arch: arch
        )
    }

    // MARK: - Full Scan

    func scan(rootPath: String, maxDepth: Int = 10, skipHidden: Bool = true) async throws -> ([Artifact], DiskInfo?, [Snapshot]) {
        let absRoot = (rootPath as NSString).standardizingPath

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absRoot, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "Scanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path is not a directory: \(absRoot)"])
        }

        async let devArtifacts = scanDevArtifacts(root: absRoot, maxDepth: maxDepth, skipHidden: skipHidden)
        async let fixedArtifacts = scanFixedPaths()
        async let dockerArtifacts = scanDocker()
        async let brewArtifacts = scanHomebrew()
        async let snapshotList = detectSnapshots()

        let allArtifacts = await deduplicateArtifacts(devArtifacts + fixedArtifacts + dockerArtifacts + brewArtifacts)
            .sorted { $0.size > $1.size }

        let diskInfo = getDiskInfo()
        let snapshots = await snapshotList

        return (allArtifacts, diskInfo, snapshots)
    }

    // MARK: - Dev Artifacts

    private func scanDevArtifacts(root: String, maxDepth: Int, skipHidden: Bool = true) async -> [Artifact] {
        let patterns = Self.patternMap()

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "scan.dev", attributes: .concurrent)
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: 20)
            var artifacts: [Artifact] = []
            let lock = NSLock()

            let fm = FileManager.default
            let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
            ) { _, _ in true }

            while let url = enumerator?.nextObject() as? URL {
                let path = url.path
                let name = url.lastPathComponent

                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

                if !isDir {
                    if name == ".DS_Store", let p = patterns[".DS_Store"] {
                        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                        lock.lock()
                        artifacts.append(Artifact(
                            path: path, name: name, size: size,
                            category: p.category, description: p.description, needsSudo: false
                        ))
                        lock.unlock()
                    }
                    continue
                }

                let rel = String(path.dropFirst(root.count + 1))
                let depth = rel.components(separatedBy: "/").count
                if maxDepth > 0 && depth > maxDepth {
                    enumerator?.skipDescendants()
                    continue
                }

                if name == "Library" && depth <= 2 {
                    enumerator?.skipDescendants()
                    continue
                }

                if let p = patterns[name] {
                    enumerator?.skipDescendants()
                    group.enter()
                    queue.async {
                        semaphore.wait()
                        let size = Self.calculateDirSize(path: path)
                        lock.lock()
                        artifacts.append(Artifact(
                            path: path, name: name, size: size,
                            category: p.category, description: p.description, needsSudo: false
                        ))
                        lock.unlock()
                        semaphore.signal()
                        group.leave()
                    }
                    continue
                }

                if skipHidden && name.hasPrefix(".") {
                    enumerator?.skipDescendants()
                    continue
                }
            }

            group.wait()
            continuation.resume(returning: artifacts)
        }
    }

    // MARK: - Fixed Paths

    private func scanFixedPaths() async -> [Artifact] {
        let fixedPaths = Self.macOSFixedPaths()

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "scan.fixed", attributes: .concurrent)
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: 10)
            var results: [Artifact] = []
            let lock = NSLock()

            for fp in fixedPaths {
                group.enter()
                queue.async {
                    semaphore.wait()
                    defer { semaphore.signal(); group.leave() }

                    let fm = FileManager.default
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: fp.path, isDirectory: &isDir) else { return }

                    let size: Int64
                    if isDir.boolValue {
                        size = Self.calculateDirSize(path: fp.path)
                    } else {
                        size = Self.physicalSize(path: fp.path)
                    }

                    guard size >= 1_048_576 else { return } // 1MB minimum

                    let artifact = Artifact(
                        path: fp.path, name: fp.name, size: size,
                        category: fp.category, description: fp.description,
                        needsSudo: fp.needsSudo,
                        isPersonalData: fp.isPersonalData
                    )
                    lock.lock()
                    results.append(artifact)
                    lock.unlock()
                }
            }

            group.wait()
            continuation.resume(returning: results)
        }
    }

    // MARK: - Docker

    /// Docker on macOS stores everything in a single sparse VM disk image. Deleting that whole
    /// folder nukes all images/containers/volumes. When the daemon is up we instead surface a
    /// `docker system prune` action sized from `docker system df`. Otherwise we fall back to the
    /// (now accurately measured) folder, clearly marked as destructive.
    private func scanDocker() async -> [Artifact] {
        let docker = DockerService()

        if let usage = docker.usage(),
           usage.safeReclaimable >= 1_048_576,
           let strategy = docker.pruneStrategy() {
            return [Artifact(
                path: strategy.commandString ?? "docker system prune",
                name: "Docker — unused images & cache",
                size: usage.safeReclaimable,
                category: .developer,
                description: "Prunes unused images, build cache & stopped containers (keeps volumes)",
                needsSudo: false,
                reclaim: strategy
            )]
        }

        return dockerFolderFallback()
    }

    /// Daemon unreachable (or nothing to prune): show the Docker data folder at its real on-disk
    /// size, flagged as a destructive full delete.
    private func dockerFolderFallback() -> [Artifact] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dataDir = (home as NSString).appendingPathComponent("Library/Containers/com.docker.docker/Data")

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dataDir, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        let size = Self.calculateDirSize(path: dataDir)
        guard size >= 1_048_576 else { return [] }

        return [Artifact(
            path: dataDir,
            name: "Docker Data (entire VM)",
            size: size,
            category: .developer,
            description: "All Docker data. Start Docker Desktop to reclaim space safely via prune.",
            needsSudo: false,
            reclaim: .deletePath,
            warning: "Deletes ALL Docker images, containers and volumes — cannot be undone."
        )]
    }

    // MARK: - Homebrew

    /// Deleting Homebrew's Cellar/Caskroom outright breaks every installed formula. The correct
    /// reclaim is `brew cleanup`, which removes only outdated versions and stale downloads.
    /// Size is taken from `brew cleanup --dry-run`.
    private func scanHomebrew() async -> [Artifact] {
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brew = candidates.first(where: { fm.isExecutableFile(atPath: $0) }),
              let out = DockerService.run(brew, ["cleanup", "--dry-run"])
        else { return [] }

        let size = Self.parseHomebrewFreeable(out)
        guard size >= 1_048_576 else { return [] }

        return [Artifact(
            path: "brew cleanup",
            name: "Homebrew cleanup",
            size: size,
            category: .caches,
            description: "Removes outdated formula versions & stale download cache (keeps installed apps)",
            needsSudo: false,
            reclaim: .command(tool: brew, args: ["cleanup"])
        )]
    }

    /// Parses brew's "This operation would free approximately 120MB of disk space." line into bytes.
    static func parseHomebrewFreeable(_ output: String) -> Int64 {
        guard let line = output.split(separator: "\n").first(where: { $0.contains("would free approximately") })
        else { return 0 }
        let pattern = #"approximately\s+([0-9]*\.?[0-9]+\s*[A-Za-z]+)"#
        let s = String(line)
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s)
        else { return 0 }
        return DockerService.parseSize(String(s[r]))
    }

    // MARK: - Snapshots

    private func detectSnapshots() async -> [Snapshot] {
        guard let output = runCommand("tmutil", "listlocalsnapshots", "/") else { return [] }

        let re = try! NSRegularExpression(pattern: #"(\d{4}-\d{2}-\d{2}-\d{6})"#)
        var snapshots: [Snapshot] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = re.firstMatch(in: trimmed, range: range),
                  let dateRange = Range(match.range(at: 1), in: trimmed) else { continue }
            snapshots.append(Snapshot(name: trimmed, date: String(trimmed[dateRange]), size: ""))
        }

        if !snapshots.isEmpty,
           let sizeOutput = runCommand("tmutil", "listlocalsnapshots", "/", "-purgeable") {
            let sizeRe = try! NSRegularExpression(pattern: #"(\d+)\s+bytes"#)
            for line in sizeOutput.components(separatedBy: "\n") {
                let range = NSRange(line.startIndex..., in: line)
                if let match = sizeRe.firstMatch(in: line, range: range),
                   let numRange = Range(match.range(at: 1), in: line),
                   let bytes = Int64(line[numRange]), bytes > 0 {
                    let perSnapshot = bytes / Int64(snapshots.count)
                    for i in snapshots.indices {
                        snapshots[i].size = formatBytes(perSnapshot)
                    }
                }
            }
        }

        return snapshots
    }

    // MARK: - Safe Delete Check

    static let protectedPaths: Set<String> = [
        "/", "/bin", "/sbin", "/usr", "/etc", "/var", "/tmp",
        "/System", "/Library", "/Applications", "/Users", "/private", "/cores"
    ]

    static func isSafeToDelete(path: String) -> Bool {
        let absPath = (path as NSString).standardizingPath
        if protectedPaths.contains(absPath) { return false }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if absPath == home { return false }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: absPath) else { return false }
        if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink { return false }

        return true
    }

    // MARK: - Delete Snapshot

    func deleteSnapshot(date: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["deletelocalsnapshots", date]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "Scanner", code: 2, userInfo: [NSLocalizedDescriptionKey: msg.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

    // MARK: - Helpers

    /// Actual on-disk allocated size of a single item, in bytes.
    /// Uses allocated blocks (like `du`) instead of logical size, so sparse files —
    /// Docker.raw, VM disk images, sparse bundles — are not wildly over-reported.
    static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
    }

    static func calculateDirSize(path: String, timeout: TimeInterval = 10, maxDepth: Int = 50) -> Int64 {
        let deadline = Date().addingTimeInterval(timeout)
        let rootURL = URL(fileURLWithPath: path)
        let fm = FileManager.default

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return allocatedSize(of: rootURL)
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        ]
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            if Date() >= deadline { break }
            if enumerator.level > maxDepth { enumerator.skipDescendants(); continue }

            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0)
            }
        }
        return total
    }

    static func physicalSize(path: String) -> Int64 {
        allocatedSize(of: URL(fileURLWithPath: path))
    }

    private func runCommand(_ args: String...) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func deduplicateArtifacts(_ artifacts: [Artifact]) -> [Artifact] {
        let sorted = artifacts.sorted { $0.path.count < $1.path.count }
        var result: [Artifact] = []
        for a in sorted {
            let nested = result.contains { existing in
                a.path.hasPrefix(existing.path + "/")
            }
            if !nested { result.append(a) }
        }
        return result
    }

    // MARK: - Patterns

    static func patternMap() -> [String: ArtifactPattern] {
        var map: [String: ArtifactPattern] = [:]
        for p in defaultPatterns() {
            map[p.name] = p
        }
        return map
    }

    static func defaultPatterns() -> [ArtifactPattern] {
        [
            // Dependencies → Developer
            ArtifactPattern(name: "node_modules", category: .developer, description: "npm/yarn/pnpm dependencies"),
            ArtifactPattern(name: ".pnpm", category: .developer, description: "pnpm store"),
            ArtifactPattern(name: "bower_components", category: .developer, description: "Bower dependencies"),
            ArtifactPattern(name: "vendor", category: .developer, description: "Vendored dependencies (Go/PHP/Ruby)"),
            ArtifactPattern(name: ".venv", category: .developer, description: "Python virtual environment"),
            ArtifactPattern(name: "venv", category: .developer, description: "Python virtual environment"),
            ArtifactPattern(name: ".bundle", category: .developer, description: "Ruby bundler"),
            ArtifactPattern(name: "Pods", category: .developer, description: "CocoaPods dependencies"),

            // Build → Developer
            ArtifactPattern(name: "dist", category: .developer, description: "Distribution build output"),
            ArtifactPattern(name: "build", category: .developer, description: "Build output directory"),
            ArtifactPattern(name: ".next", category: .developer, description: "Next.js build output"),
            ArtifactPattern(name: ".nuxt", category: .developer, description: "Nuxt.js build output"),
            ArtifactPattern(name: ".output", category: .developer, description: "Nuxt 3 build output"),
            ArtifactPattern(name: "target", category: .developer, description: "Rust/Java/Scala build output"),
            ArtifactPattern(name: ".svelte-kit", category: .developer, description: "SvelteKit build output"),
            ArtifactPattern(name: ".angular", category: .developer, description: "Angular cache/build"),
            ArtifactPattern(name: "storybook-static", category: .developer, description: "Storybook build output"),

            // Project caches → Caches
            ArtifactPattern(name: ".parcel-cache", category: .caches, description: "Parcel bundler cache"),
            ArtifactPattern(name: ".turbo", category: .caches, description: "Turborepo cache"),
            ArtifactPattern(name: ".pytest_cache", category: .caches, description: "Pytest cache"),
            ArtifactPattern(name: "__pycache__", category: .caches, description: "Python bytecode cache"),
            ArtifactPattern(name: ".eslintcache", category: .caches, description: "ESLint cache"),
            ArtifactPattern(name: ".sass-cache", category: .caches, description: "Sass preprocessor cache"),
            ArtifactPattern(name: ".webpack", category: .caches, description: "Webpack cache"),
            ArtifactPattern(name: ".gradle", category: .caches, description: "Gradle cache"),
            ArtifactPattern(name: ".dart_tool", category: .caches, description: "Dart tool cache"),

            // Coverage → Developer
            ArtifactPattern(name: "coverage", category: .developer, description: "Code coverage reports"),
            ArtifactPattern(name: ".nyc_output", category: .developer, description: "NYC coverage output"),
            ArtifactPattern(name: "htmlcov", category: .developer, description: "Python HTML coverage reports"),

            // Infrastructure → Developer
            ArtifactPattern(name: ".terraform", category: .developer, description: "Terraform provider cache"),

            // Misc → System
            ArtifactPattern(name: ".DS_Store", category: .system, description: "macOS directory metadata"),
        ]
    }

    static func macOSFixedPaths() -> [FixedPath] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func hp(_ components: String...) -> String {
            var p = home
            for c in components { p = (p as NSString).appendingPathComponent(c) }
            return p
        }

        return [
            // ---- Caches (safe to delete; apps regenerate them) ----
            FixedPath(path: hp("Library", "Caches"), name: "User Caches", category: .caches,
                      description: "All application caches (Safari, Chrome, Spotify, pip, etc.)", needsSudo: false),
            FixedPath(path: "/Library/Caches", name: "System Caches", category: .caches,
                      description: "System-level application caches", needsSudo: true),
            FixedPath(path: hp("Library", "Containers", "com.apple.Safari", "Data", "Library", "Caches"), name: "Safari Container Cache", category: .caches,
                      description: "Safari sandboxed cache", needsSudo: false),

            // Package-manager caches → Caches
            FixedPath(path: hp(".npm", "_cacache"), name: "npm Cache", category: .caches,
                      description: "npm content-addressable cache", needsSudo: false),
            FixedPath(path: hp(".cache", "pnpm"), name: "pnpm Cache", category: .caches,
                      description: "pnpm global store cache", needsSudo: false),
            FixedPath(path: hp(".pnpm-store"), name: "pnpm Store", category: .caches,
                      description: "pnpm global content-addressable store", needsSudo: false),
            FixedPath(path: hp("go", "pkg", "mod", "cache"), name: "Go Module Cache", category: .caches,
                      description: "Go module download cache", needsSudo: false),
            FixedPath(path: hp(".cargo", "registry"), name: "Cargo Registry", category: .caches,
                      description: "Rust cargo crate registry cache", needsSudo: false),
            FixedPath(path: hp(".cargo", "git"), name: "Cargo Git Cache", category: .caches,
                      description: "Rust cargo git dependency cache", needsSudo: false),
            FixedPath(path: hp(".m2", "repository"), name: "Maven Cache", category: .caches,
                      description: "Maven local repository cache", needsSudo: false),
            FixedPath(path: hp(".gradle", "caches"), name: "Gradle Caches", category: .caches,
                      description: "Gradle build caches", needsSudo: false),
            FixedPath(path: hp(".gradle", "wrapper", "dists"), name: "Gradle Wrapper Dists", category: .caches,
                      description: "Downloaded Gradle wrapper distributions", needsSudo: false),
            FixedPath(path: hp(".composer", "cache"), name: "Composer Cache", category: .caches,
                      description: "PHP Composer cache", needsSudo: false),
            FixedPath(path: hp(".gem", "cache"), name: "RubyGems Cache", category: .caches,
                      description: "RubyGems download cache", needsSudo: false),
            FixedPath(path: hp(".cocoapods", "repos"), name: "CocoaPods Repos", category: .caches,
                      description: "CocoaPods spec repositories (~1-3GB)", needsSudo: false),
            FixedPath(path: hp(".pub-cache"), name: "Dart/Flutter Cache", category: .caches,
                      description: "Dart pub package cache", needsSudo: false),
            FixedPath(path: hp(".nuget", "packages"), name: "NuGet Cache", category: .caches,
                      description: ".NET NuGet package cache", needsSudo: false),

            // App caches → Caches
            FixedPath(path: hp("Library", "Application Support", "Code", "Cache"), name: "VS Code Cache", category: .caches,
                      description: "Visual Studio Code cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Code", "CachedData"), name: "VS Code CachedData", category: .caches,
                      description: "VS Code cached bytecode", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Code", "CachedExtensionVSIXs"), name: "VS Code Extension Cache", category: .caches,
                      description: "VS Code cached extension downloads", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Code", "User", "workspaceStorage"), name: "VS Code Workspace Storage", category: .caches,
                      description: "VS Code per-workspace data (search index, etc.)", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Slack", "Cache"), name: "Slack Cache", category: .caches,
                      description: "Slack app cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Slack", "Service Worker", "CacheStorage"), name: "Slack Service Worker", category: .caches,
                      description: "Slack service worker cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "discord", "Cache"), name: "Discord Cache", category: .caches,
                      description: "Discord app cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Microsoft Teams", "Cache"), name: "Teams Cache", category: .caches,
                      description: "Microsoft Teams cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Figma", "Cache"), name: "Figma Cache", category: .caches,
                      description: "Figma desktop app cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Zoom", "data"), name: "Zoom Data", category: .caches,
                      description: "Zoom recordings, cache and data", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Telegram Desktop", "tdata", "user_data"), name: "Telegram Cache", category: .caches,
                      description: "Telegram media & message cache", needsSudo: false),

            // ---- System (logs, crashes, temp, indexes) ----
            FixedPath(path: hp("Library", "Logs"), name: "User Logs", category: .system,
                      description: "Application log files", needsSudo: false),
            FixedPath(path: hp(".Trash"), name: "Trash", category: .system,
                      description: "Files in Trash (not yet permanently deleted)", needsSudo: false),
            FixedPath(path: "/var/log", name: "System Logs", category: .system,
                      description: "System log files (asl, install, wifi, etc.)", needsSudo: true),
            FixedPath(path: "/private/var/folders", name: "Temporary Items", category: .system,
                      description: "Per-user temporary files & caches (managed by macOS)", needsSudo: true),
            FixedPath(path: hp("Library", "Logs", "DiagnosticReports"), name: "User Crash Reports", category: .system,
                      description: "Application crash logs (.ips, .crash files)", needsSudo: false),
            FixedPath(path: "/Library/Logs/DiagnosticReports", name: "System Crash Reports", category: .system,
                      description: "System-level crash & hang reports", needsSudo: true),
            FixedPath(path: "/cores", name: "Core Dumps", category: .system,
                      description: "Process core dump files (can be 1-10GB each)", needsSudo: true),
            FixedPath(path: hp("Library", "Logs", "JetBrains"), name: "JetBrains Logs", category: .system,
                      description: "IntelliJ/WebStorm/PyCharm IDE logs", needsSudo: false),
            FixedPath(path: hp("Library", "Saved Application State"), name: "Saved App State", category: .system,
                      description: "Window positions & states of closed apps", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "CrashReporter"), name: "App Crash Reporter", category: .system,
                      description: "Application crash report data", needsSudo: false),
            FixedPath(path: "/tmp", name: "System Temp", category: .system,
                      description: "System temporary files", needsSudo: true),
            FixedPath(path: "/private/var/tmp", name: "Private Temp", category: .system,
                      description: "Persistent temporary files (survive reboot)", needsSudo: true),
            FixedPath(path: hp("Library", "Metadata", "CoreSpotlight"), name: "Spotlight Index", category: .system,
                      description: "Spotlight search index data (rebuilds automatically)", needsSudo: false),

            // ---- Developer (Xcode, Docker, VMs, SDKs) ----
            FixedPath(path: hp("Library", "Developer", "Xcode", "DerivedData"), name: "Xcode DerivedData", category: .developer,
                      description: "Build intermediates & indexes (often 10-50GB+)", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "Archives"), name: "Xcode Archives", category: .developer,
                      description: "Archived app builds (.xcarchive)", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "iOS DeviceSupport"), name: "iOS DeviceSupport", category: .developer,
                      description: "Debug symbols for connected iOS devices (2-5GB per iOS version)", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "watchOS DeviceSupport"), name: "watchOS DeviceSupport", category: .developer,
                      description: "Debug symbols for connected Apple Watch", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "tvOS DeviceSupport"), name: "tvOS DeviceSupport", category: .developer,
                      description: "Debug symbols for Apple TV", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "CoreSimulator", "Devices"), name: "iOS Simulators", category: .developer,
                      description: "iOS/watchOS/tvOS simulator data (can be 20GB+)", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "CoreSimulator", "Caches"), name: "Simulator Caches", category: .developer,
                      description: "Simulator runtime caches", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "UserData", "IB Support"), name: "Xcode IB Support", category: .developer,
                      description: "Interface Builder support cache", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "Products"), name: "Xcode Products", category: .developer,
                      description: "Built products from Xcode", needsSudo: false),
            FixedPath(path: "/Library/Developer/CommandLineTools", name: "Xcode CLI Tools", category: .developer,
                      description: "Command Line Tools for Xcode (~1-2GB)", needsSudo: true),
            FixedPath(path: "/Library/Developer/CoreSimulator", name: "Simulator Runtimes", category: .developer,
                      description: "Downloaded iOS/watchOS/tvOS simulator runtimes (5-10GB each)", needsSudo: true),

            // Docker — the VM data image is handled by scanDocker() (prune when daemon is up,
            // accurate folder size as fallback). Only the lightweight CLI config is a fixed path here.
            FixedPath(path: hp(".docker"), name: "Docker Config & Cache", category: .developer,
                      description: "Docker CLI config, buildx cache", needsSudo: false),

            // VMs & SDKs
            FixedPath(path: hp(".android", "avd"), name: "Android Emulator AVDs", category: .developer,
                      description: "Android emulator virtual device images (2-10GB each)", needsSudo: false),
            FixedPath(path: hp("Library", "Android", "sdk"), name: "Android SDK", category: .developer,
                      description: "Android SDK, build tools, platform images", needsSudo: false),
            FixedPath(path: hp("Parallels"), name: "Parallels VMs", category: .developer,
                      description: "Parallels Desktop virtual machine images (20-60GB each)", needsSudo: false),
            FixedPath(path: hp("Virtual Machines.localized"), name: "VMware VMs", category: .developer,
                      description: "VMware Fusion virtual machine images", needsSudo: false),
            FixedPath(path: hp("VirtualBox VMs"), name: "VirtualBox VMs", category: .developer,
                      description: "VirtualBox virtual machine images", needsSudo: false),

            // ---- Media (re-downloadable media caches) ----
            FixedPath(path: hp("Library", "Group Containers", "243LU875E5.groups.com.apple.podcasts"), name: "Apple Podcasts", category: .media,
                      description: "Downloaded podcast episodes", needsSudo: false),
            FixedPath(path: hp("Library", "Group Containers", "group.com.apple.music"), name: "Apple Music Cache", category: .media,
                      description: "Offline Apple Music downloads & cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Spotify", "PersistentCache"), name: "Spotify Cache", category: .media,
                      description: "Spotify offline/streaming cache", needsSudo: false),

            // ---- Personal data (flagged; excluded from Select All; warned before delete) ----
            FixedPath(path: hp("Downloads"), name: "Downloads", category: .personal,
                      description: "Your Downloads folder — review before deleting!", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "Application Support", "MobileSync", "Backup"), name: "iPhone/iPad Backups", category: .personal,
                      description: "Local iOS device backups (10-50GB each!)", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "Mail"), name: "Apple Mail Data", category: .personal,
                      description: "Mail messages & attachments (years of email)", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "Mail Downloads"), name: "Mail Downloads", category: .personal,
                      description: "Opened mail attachment files", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "Messages", "Attachments"), name: "iMessage Attachments", category: .personal,
                      description: "Photos/videos/files received via iMessage", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Movies"), name: "Movies", category: .personal,
                      description: "Movie files, screen recordings, Final Cut projects", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Music"), name: "Music Library", category: .personal,
                      description: "Music files, GarageBand projects, Logic Pro data", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Pictures", "Photos Library.photoslibrary"), name: "Photos Library", category: .personal,
                      description: "Apple Photos library (originals + thumbnails)", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "Application Support", "Steam"), name: "Steam Games", category: .personal,
                      description: "Steam game installations and data", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "Safari"), name: "Safari Data", category: .personal,
                      description: "Safari history, bookmarks, local storage, databases", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "WebKit"), name: "WebKit Data", category: .personal,
                      description: "WebKit local storage, databases, service workers", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "Cookies"), name: "Cookies", category: .personal,
                      description: "Browser and app cookies (logs you out)", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "Application Support", "Google", "Chrome"), name: "Chrome Profile Data", category: .personal,
                      description: "Chrome profiles, extensions, local storage", needsSudo: false, isPersonalData: true),
            FixedPath(path: hp("Library", "Application Support", "Firefox"), name: "Firefox Profile Data", category: .personal,
                      description: "Firefox profiles, extensions, local storage", needsSudo: false, isPersonalData: true),
        ]
    }
}
