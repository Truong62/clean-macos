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

    func scan(rootPath: String, maxDepth: Int = 10) async throws -> ([Artifact], DiskInfo?, [Snapshot]) {
        let absRoot = (rootPath as NSString).standardizingPath

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absRoot, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(domain: "Scanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path is not a directory: \(absRoot)"])
        }

        async let devArtifacts = scanDevArtifacts(root: absRoot, maxDepth: maxDepth)
        async let fixedArtifacts = scanFixedPaths()
        async let snapshotList = detectSnapshots()

        let allArtifacts = await deduplicateArtifacts(devArtifacts + fixedArtifacts)
            .sorted { $0.size > $1.size }

        let diskInfo = getDiskInfo()
        let snapshots = await snapshotList

        return (allArtifacts, diskInfo, snapshots)
    }

    // MARK: - Dev Artifacts

    private func scanDevArtifacts(root: String, maxDepth: Int) async -> [Artifact] {
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

                if name.hasPrefix(".") {
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
                        needsSudo: fp.needsSudo
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

    static func calculateDirSize(path: String, timeout: TimeInterval = 10, maxDepth: Int = 50) -> Int64 {
        let deadline = Date().addingTimeInterval(timeout)
        return calcDirSizeRecursive(path: path, depth: 0, maxDepth: maxDepth, deadline: deadline)
    }

    private static func calcDirSizeRecursive(path: String, depth: Int, maxDepth: Int, deadline: Date) -> Int64 {
        guard Date() < deadline, depth <= maxDepth else { return 0 }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return 0 }

        var total: Int64 = 0
        for entry in entries {
            guard Date() < deadline else { break }
            let full = (path as NSString).appendingPathComponent(entry)

            guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
            let type = attrs[.type] as? FileAttributeType

            if type == .typeSymbolicLink { continue }

            if type == .typeDirectory {
                total += calcDirSizeRecursive(path: full, depth: depth + 1, maxDepth: maxDepth, deadline: deadline)
            } else {
                total += physicalSize(attrs: attrs)
            }
        }
        return total
    }

    static func physicalSize(path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        return physicalSize(attrs: attrs)
    }

    private static func physicalSize(attrs: [FileAttributeKey: Any]) -> Int64 {
        // Try to get actual allocated size via stat
        if let size = attrs[.size] as? Int64 {
            return size
        }
        return (attrs[.size] as? Int) .map { Int64($0) } ?? 0
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
            // Dependencies
            ArtifactPattern(name: "node_modules", category: .dependencies, description: "npm/yarn/pnpm dependencies"),
            ArtifactPattern(name: ".pnpm", category: .dependencies, description: "pnpm store"),
            ArtifactPattern(name: "bower_components", category: .dependencies, description: "Bower dependencies"),
            ArtifactPattern(name: "vendor", category: .dependencies, description: "Vendored dependencies (Go/PHP/Ruby)"),
            ArtifactPattern(name: ".venv", category: .dependencies, description: "Python virtual environment"),
            ArtifactPattern(name: "venv", category: .dependencies, description: "Python virtual environment"),
            ArtifactPattern(name: ".bundle", category: .dependencies, description: "Ruby bundler"),
            ArtifactPattern(name: "Pods", category: .dependencies, description: "CocoaPods dependencies"),

            // Build
            ArtifactPattern(name: "dist", category: .build, description: "Distribution build output"),
            ArtifactPattern(name: "build", category: .build, description: "Build output directory"),
            ArtifactPattern(name: ".next", category: .build, description: "Next.js build output"),
            ArtifactPattern(name: ".nuxt", category: .build, description: "Nuxt.js build output"),
            ArtifactPattern(name: ".output", category: .build, description: "Nuxt 3 build output"),
            ArtifactPattern(name: "target", category: .build, description: "Rust/Java/Scala build output"),
            ArtifactPattern(name: ".svelte-kit", category: .build, description: "SvelteKit build output"),
            ArtifactPattern(name: ".angular", category: .build, description: "Angular cache/build"),
            ArtifactPattern(name: "storybook-static", category: .build, description: "Storybook build output"),

            // Cache
            ArtifactPattern(name: ".parcel-cache", category: .cache, description: "Parcel bundler cache"),
            ArtifactPattern(name: ".turbo", category: .cache, description: "Turborepo cache"),
            ArtifactPattern(name: ".pytest_cache", category: .cache, description: "Pytest cache"),
            ArtifactPattern(name: "__pycache__", category: .cache, description: "Python bytecode cache"),
            ArtifactPattern(name: ".eslintcache", category: .cache, description: "ESLint cache"),
            ArtifactPattern(name: ".sass-cache", category: .cache, description: "Sass preprocessor cache"),
            ArtifactPattern(name: ".webpack", category: .cache, description: "Webpack cache"),
            ArtifactPattern(name: ".gradle", category: .cache, description: "Gradle cache"),
            ArtifactPattern(name: ".dart_tool", category: .cache, description: "Dart tool cache"),

            // Coverage
            ArtifactPattern(name: "coverage", category: .coverage, description: "Code coverage reports"),
            ArtifactPattern(name: ".nyc_output", category: .coverage, description: "NYC coverage output"),
            ArtifactPattern(name: "htmlcov", category: .coverage, description: "Python HTML coverage reports"),

            // Infrastructure
            ArtifactPattern(name: ".terraform", category: .infrastructure, description: "Terraform provider cache"),

            // Misc
            ArtifactPattern(name: ".DS_Store", category: .misc, description: "macOS directory metadata"),
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
            FixedPath(path: hp("Library", "Caches"), name: "User Caches", category: .system,
                      description: "All application caches (Safari, Chrome, Spotify, Homebrew, pip, etc.)", needsSudo: false),
            FixedPath(path: hp("Library", "Logs"), name: "User Logs", category: .logs,
                      description: "Application log files", needsSudo: false),
            FixedPath(path: hp(".Trash"), name: "Trash", category: .system,
                      description: "Files in Trash (not yet permanently deleted)", needsSudo: false),
            FixedPath(path: "/Library/Caches", name: "System Caches", category: .system,
                      description: "System-level application caches", needsSudo: true),
            FixedPath(path: "/var/log", name: "System Logs", category: .logs,
                      description: "System log files (asl, install, wifi, etc.)", needsSudo: true),
            FixedPath(path: "/private/var/folders", name: "Temporary Items", category: .system,
                      description: "Per-user temporary files & caches (managed by macOS)", needsSudo: true),
            FixedPath(path: hp("Library", "Logs", "DiagnosticReports"), name: "User Crash Reports", category: .crash,
                      description: "Application crash logs (.ips, .crash files)", needsSudo: false),
            FixedPath(path: "/Library/Logs/DiagnosticReports", name: "System Crash Reports", category: .crash,
                      description: "System-level crash & hang reports", needsSudo: true),
            FixedPath(path: "/cores", name: "Core Dumps", category: .crash,
                      description: "Process core dump files (can be 1-10GB each)", needsSudo: true),
            FixedPath(path: hp("Library", "Logs", "JetBrains"), name: "JetBrains Logs", category: .crash,
                      description: "IntelliJ/WebStorm/PyCharm IDE logs", needsSudo: false),

            // Xcode
            FixedPath(path: hp("Library", "Developer", "Xcode", "DerivedData"), name: "Xcode DerivedData", category: .xcode,
                      description: "Build intermediates & indexes (often 10-50GB+)", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "Archives"), name: "Xcode Archives", category: .xcode,
                      description: "Archived app builds (.xcarchive)", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "iOS DeviceSupport"), name: "iOS DeviceSupport", category: .xcode,
                      description: "Debug symbols for connected iOS devices (2-5GB per iOS version)", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "watchOS DeviceSupport"), name: "watchOS DeviceSupport", category: .xcode,
                      description: "Debug symbols for connected Apple Watch", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "tvOS DeviceSupport"), name: "tvOS DeviceSupport", category: .xcode,
                      description: "Debug symbols for Apple TV", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "CoreSimulator", "Devices"), name: "iOS Simulators", category: .xcode,
                      description: "iOS/watchOS/tvOS simulator data (can be 20GB+)", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "CoreSimulator", "Caches"), name: "Simulator Caches", category: .xcode,
                      description: "Simulator runtime caches", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "UserData", "IB Support"), name: "Xcode IB Support", category: .xcode,
                      description: "Interface Builder support cache", needsSudo: false),
            FixedPath(path: hp("Library", "Developer", "Xcode", "Products"), name: "Xcode Products", category: .xcode,
                      description: "Built products from Xcode", needsSudo: false),

            // Docker
            FixedPath(path: hp("Library", "Containers", "com.docker.docker", "Data"), name: "Docker Data", category: .docker,
                      description: "Docker images, containers, volumes", needsSudo: false),
            FixedPath(path: hp(".docker"), name: "Docker Config & Cache", category: .docker,
                      description: "Docker CLI config, buildx cache", needsSudo: false),

            // Backup
            FixedPath(path: hp("Library", "Application Support", "MobileSync", "Backup"), name: "iPhone/iPad Backups", category: .backup,
                      description: "Local iOS device backups (10-50GB each!)", needsSudo: false),

            // VMs
            FixedPath(path: hp(".android", "avd"), name: "Android Emulator AVDs", category: .vm,
                      description: "Android emulator virtual device images (2-10GB each)", needsSudo: false),
            FixedPath(path: hp("Library", "Android", "sdk"), name: "Android SDK", category: .infrastructure,
                      description: "Android SDK, build tools, platform images", needsSudo: false),
            FixedPath(path: hp("Parallels"), name: "Parallels VMs", category: .vm,
                      description: "Parallels Desktop virtual machine images (20-60GB each)", needsSudo: false),
            FixedPath(path: hp("Virtual Machines.localized"), name: "VMware VMs", category: .vm,
                      description: "VMware Fusion virtual machine images", needsSudo: false),
            FixedPath(path: hp("VirtualBox VMs"), name: "VirtualBox VMs", category: .vm,
                      description: "VirtualBox virtual machine images", needsSudo: false),

            // Mail
            FixedPath(path: hp("Library", "Mail"), name: "Apple Mail Data", category: .mail,
                      description: "Mail messages & attachments (can grow to many GB over years)", needsSudo: false),
            FixedPath(path: hp("Library", "Mail Downloads"), name: "Mail Downloads", category: .mail,
                      description: "Opened mail attachment files", needsSudo: false),

            // Media
            FixedPath(path: hp("Library", "Group Containers", "243LU875E5.groups.com.apple.podcasts"), name: "Apple Podcasts", category: .media,
                      description: "Downloaded podcast episodes", needsSudo: false),
            FixedPath(path: hp("Library", "Group Containers", "group.com.apple.music"), name: "Apple Music Cache", category: .media,
                      description: "Offline Apple Music downloads & cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Spotify", "PersistentCache"), name: "Spotify Cache", category: .media,
                      description: "Spotify offline/streaming cache", needsSudo: false),
            FixedPath(path: hp("Downloads"), name: "Downloads", category: .downloads,
                      description: "Your Downloads folder (review before deleting!)", needsSudo: false),

            // Package manager caches
            FixedPath(path: hp(".npm", "_cacache"), name: "npm Cache", category: .cache,
                      description: "npm content-addressable cache", needsSudo: false),
            FixedPath(path: hp(".cache", "pnpm"), name: "pnpm Cache", category: .cache,
                      description: "pnpm global store cache", needsSudo: false),
            FixedPath(path: hp(".pnpm-store"), name: "pnpm Store", category: .cache,
                      description: "pnpm global content-addressable store", needsSudo: false),
            FixedPath(path: hp("go", "pkg", "mod", "cache"), name: "Go Module Cache", category: .cache,
                      description: "Go module download cache", needsSudo: false),
            FixedPath(path: hp(".cargo", "registry"), name: "Cargo Registry", category: .cache,
                      description: "Rust cargo crate registry cache", needsSudo: false),
            FixedPath(path: hp(".cargo", "git"), name: "Cargo Git Cache", category: .cache,
                      description: "Rust cargo git dependency cache", needsSudo: false),
            FixedPath(path: hp(".m2", "repository"), name: "Maven Cache", category: .cache,
                      description: "Maven local repository cache", needsSudo: false),
            FixedPath(path: hp(".gradle", "caches"), name: "Gradle Caches", category: .cache,
                      description: "Gradle build caches", needsSudo: false),
            FixedPath(path: hp(".gradle", "wrapper", "dists"), name: "Gradle Wrapper Dists", category: .cache,
                      description: "Downloaded Gradle wrapper distributions", needsSudo: false),
            FixedPath(path: hp(".composer", "cache"), name: "Composer Cache", category: .cache,
                      description: "PHP Composer cache", needsSudo: false),
            FixedPath(path: hp(".gem", "cache"), name: "RubyGems Cache", category: .cache,
                      description: "RubyGems download cache", needsSudo: false),
            FixedPath(path: hp(".cocoapods", "repos"), name: "CocoaPods Repos", category: .cache,
                      description: "CocoaPods spec repositories (~1-3GB)", needsSudo: false),
            FixedPath(path: hp(".pub-cache"), name: "Dart/Flutter Cache", category: .cache,
                      description: "Dart pub package cache", needsSudo: false),
            FixedPath(path: hp(".nuget", "packages"), name: "NuGet Cache", category: .cache,
                      description: ".NET NuGet package cache", needsSudo: false),

            // App caches
            FixedPath(path: hp("Library", "Application Support", "Code", "Cache"), name: "VS Code Cache", category: .cache,
                      description: "Visual Studio Code cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Code", "CachedData"), name: "VS Code CachedData", category: .cache,
                      description: "VS Code cached bytecode", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Code", "CachedExtensionVSIXs"), name: "VS Code Extension Cache", category: .cache,
                      description: "VS Code cached extension downloads", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Code", "User", "workspaceStorage"), name: "VS Code Workspace Storage", category: .cache,
                      description: "VS Code per-workspace data (search index, etc.)", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Slack", "Cache"), name: "Slack Cache", category: .cache,
                      description: "Slack app cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Slack", "Service Worker", "CacheStorage"), name: "Slack Service Worker", category: .cache,
                      description: "Slack service worker cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "discord", "Cache"), name: "Discord Cache", category: .cache,
                      description: "Discord app cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Microsoft Teams", "Cache"), name: "Teams Cache", category: .cache,
                      description: "Microsoft Teams cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Figma", "Cache"), name: "Figma Cache", category: .cache,
                      description: "Figma desktop app cache", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Zoom", "data"), name: "Zoom Data", category: .cache,
                      description: "Zoom recordings, cache and data", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Telegram Desktop", "tdata", "user_data"), name: "Telegram Cache", category: .cache,
                      description: "Telegram media & message cache", needsSudo: false),

            // System
            FixedPath(path: hp("Library", "Containers", "com.apple.Safari", "Data", "Library", "Caches"), name: "Safari Container Cache", category: .system,
                      description: "Safari sandboxed cache", needsSudo: false),
            FixedPath(path: hp("Library", "Saved Application State"), name: "Saved App State", category: .misc,
                      description: "Window positions & states of closed apps", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "CrashReporter"), name: "App Crash Reporter", category: .crash,
                      description: "Application crash report data", needsSudo: false),
            FixedPath(path: "/tmp", name: "System Temp", category: .system,
                      description: "System temporary files", needsSudo: true),
            FixedPath(path: "/private/var/tmp", name: "Private Temp", category: .system,
                      description: "Persistent temporary files (survive reboot)", needsSudo: true),

            FixedPath(path: hp("Library", "Messages", "Attachments"), name: "iMessage Attachments", category: .system,
                      description: "Photos/videos/files received via iMessage", needsSudo: false),
            FixedPath(path: hp("Movies"), name: "Movies", category: .media,
                      description: "Movie files, screen recordings, Final Cut projects", needsSudo: false),
            FixedPath(path: hp("Music"), name: "Music Library", category: .media,
                      description: "Music files, GarageBand projects, Logic Pro data", needsSudo: false),
            FixedPath(path: hp("Pictures", "Photos Library.photoslibrary"), name: "Photos Library", category: .media,
                      description: "Apple Photos library (originals + thumbnails)", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Steam"), name: "Steam Games", category: .media,
                      description: "Steam game installations and data", needsSudo: false),

            FixedPath(path: hp("Library", "Metadata", "CoreSpotlight"), name: "Spotlight Index", category: .system,
                      description: "Spotlight search index data", needsSudo: false),
            FixedPath(path: hp("Library", "Safari"), name: "Safari Data", category: .system,
                      description: "Safari history, bookmarks, local storage, databases", needsSudo: false),
            FixedPath(path: hp("Library", "WebKit"), name: "WebKit Data", category: .system,
                      description: "WebKit local storage, databases, service workers", needsSudo: false),
            FixedPath(path: hp("Library", "Cookies"), name: "Cookies", category: .system,
                      description: "Browser and app cookies", needsSudo: false),

            // Homebrew
            FixedPath(path: "/usr/local/Cellar", name: "Homebrew Cellar", category: .infrastructure,
                      description: "Installed Homebrew formula versions", needsSudo: false),
            FixedPath(path: "/usr/local/Caskroom", name: "Homebrew Caskroom", category: .infrastructure,
                      description: "Installed Homebrew cask app versions", needsSudo: false),
            FixedPath(path: "/opt/homebrew/Cellar", name: "Homebrew Cellar (ARM)", category: .infrastructure,
                      description: "Installed Homebrew formula versions (Apple Silicon)", needsSudo: false),
            FixedPath(path: "/opt/homebrew/Caskroom", name: "Homebrew Caskroom (ARM)", category: .infrastructure,
                      description: "Installed Homebrew cask versions (Apple Silicon)", needsSudo: false),

            // Browsers
            FixedPath(path: hp("Library", "Application Support", "Google", "Chrome"), name: "Chrome Profile Data", category: .system,
                      description: "Chrome profiles, extensions, local storage", needsSudo: false),
            FixedPath(path: hp("Library", "Application Support", "Firefox"), name: "Firefox Profile Data", category: .system,
                      description: "Firefox profiles, extensions, local storage", needsSudo: false),

            // System (sudo)
            FixedPath(path: "/Library/Developer/CommandLineTools", name: "Xcode CLI Tools", category: .xcode,
                      description: "Command Line Tools for Xcode (~1-2GB)", needsSudo: true),
            FixedPath(path: "/Library/Developer/CoreSimulator", name: "Simulator Runtimes", category: .xcode,
                      description: "Downloaded iOS/watchOS/tvOS simulator runtimes (5-10GB each)", needsSudo: true),
        ]
    }
}
