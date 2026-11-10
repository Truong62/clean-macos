import AppKit

struct BrewClient: Sendable {
    static let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let quietEnvironment = ["HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_ENV_HINTS=1", "HOMEBREW_NO_COLOR=1"]
    static let jobEnvironment = ["HOMEBREW_NO_ENV_HINTS": "1", "HOMEBREW_NO_COLOR": "1"]

    let path: String

    static func locate(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> BrewClient? {
        candidates.first(where: isExecutable).map(BrewClient.init(path:))
    }

    func installed() -> [BrewPackage]? {
        installedWithWarnings().packages
    }

    func installedWithWarnings() -> (packages: [BrewPackage]?, warnings: String) {
        let result = run(["info", "--json=v2", "--installed"])
        let packages = BrewJSON.packages(from: Data(result.output.utf8))?.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (packages, result.error)
    }

    func outdated(greedyCasks: Bool = false) -> [BrewOutdated]? {
        BrewJSON.outdated(from: read(greedyCasks ? ["outdated", "--cask", "--greedy", "--json=v2"] : ["outdated", "--json=v2"]))
    }

    func search(_ query: String, kind: BrewKind) -> [String] {
        BrewJSON.searchResults(read(["search", kind.flag, query]))
    }

    func info(_ name: String, kind: BrewKind) -> BrewPackage? {
        BrewJSON.packages(from: Data(read(["info", "--json=v2", kind.flag, name]).utf8))?.first
    }

    private func read(_ arguments: [String]) -> String {
        run(arguments).output
    }

    private func run(_ arguments: [String]) -> CommandResult {
        CommandRunner.run("/usr/bin/env", Self.quietEnvironment + [path] + arguments)
    }
}

final class BrewProcess: @unchecked Sendable {
    static let killDelay: TimeInterval = 2
    static let flushLimit = 64 * 1024

    private let process = Process()

    func start(_ path: String, _ arguments: [String], output: @escaping @Sendable (String) -> Void,
               finished: @escaping @Sendable (Int32) -> Void) throws {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(BrewClient.jobEnvironment) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var pending = Data()
            while case let data = handle.availableData, !data.isEmpty {
                pending.append(data)
                if let text = String(data: pending, encoding: .utf8) {
                    output(text)
                    pending.removeAll()
                } else if pending.count > Self.flushLimit {
                    output(String(decoding: pending, as: UTF8.self))
                    pending.removeAll()
                }
            }
            if !pending.isEmpty { output(String(decoding: pending, as: UTF8.self)) }
            process.waitUntilExit()
            finished(process.terminationStatus)
        }
    }

    func cancel() {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killDelay) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

struct DownloadCache: Sendable {
    static let standard = DownloadCache(folder: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CleanMacOS", isDirectory: true))

    let folder: URL

    func cached(_ name: String, maxAge: TimeInterval, now: Date = Date()) -> Data? {
        let url = folder.appendingPathComponent(name)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(modified) < maxAge else { return nil }
        return try? Data(contentsOf: url)
    }

    func store(_ data: Data, as name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    func data(from url: URL, name: String, maxAge: TimeInterval) async -> Data? {
        if let fresh = cached(name, maxAge: maxAge) { return fresh }
        guard let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 else {
            return cached(name, maxAge: .infinity)
        }
        store(data, as: name)
        return data
    }
}

extension TerminalScript {
    @discardableResult
    static func open(_ command: String) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacKit-\(UUID().uuidString).command")
        do {
            try contents(for: command).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}

@MainActor
final class HomebrewController: ObservableObject {
    static let analyticsLife: TimeInterval = 86_400
    static let analytics: [(BrewKind, URL)] = [
        (.formula, URL(string: "https://formulae.brew.sh/api/analytics/install/30d.json")!),
        (.cask, URL(string: "https://formulae.brew.sh/api/analytics/cask-install/30d.json")!),
    ]

    @Published private(set) var client = BrewClient.locate()
    @Published private(set) var packages: [BrewPackage] = []
    @Published private(set) var tree = BrewTree([])
    @Published private(set) var outdated: [String: BrewOutdated] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var results: [BrewSearchHit] = []
    @Published private(set) var searchedQuery = ""
    @Published private(set) var isSearching = false
    @Published private(set) var popularity: [String: Int] = [:]
    @Published private(set) var job: BrewJob?
    @Published private(set) var untrustedTap: String?
    @Published var message = ""

    private var process: BrewProcess?
    private var completion: (@MainActor () async -> Void)?
    private var needsRefresh = false

    var isBusy: Bool { job?.isRunning == true }
    var upgradable: [BrewOutdated] { outdated.values.filter { !$0.isPinned } }

    func outdatedEntry(for package: BrewPackage) -> BrewOutdated? {
        outdated["\(package.kind.rawValue):\(package.fullName)"] ?? outdated["\(package.kind.rawValue):\(package.name)"]
    }

    func installedPackage(for hit: BrewSearchHit) -> BrewPackage? {
        packages.first { $0.kind == hit.kind && ($0.name == hit.name || $0.fullName == hit.name) }
    }

    func loadIfNeeded() async {
        client = BrewClient.locate()
        if client != nil && !hasLoaded { await refresh() }
    }

    func refresh() async {
        client = BrewClient.locate()
        guard let client else { return }
        guard !isLoading else {
            needsRefresh = true
            return
        }
        isLoading = true
        async let installed = Task.detached { client.installedWithWarnings() }.value
        async let outdatedList = Task.detached { client.outdated() }.value
        let (found, stale) = await (installed, outdatedList)
        packages = found.packages ?? []
        tree = BrewTree(packages)
        outdated = Dictionary((stale ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        untrustedTap = BrewSignals.untrustedTap(found.warnings)
        message = found.packages == nil ? "Homebrew did not return its list of installed packages." : ""
        isLoading = false
        hasLoaded = true
        if needsRefresh {
            needsRefresh = false
            await refresh()
        }
    }

    func search(_ query: String) async {
        let text = String(query.trimmingCharacters(in: .whitespaces).drop { $0 == "-" })
        guard let client, !text.isEmpty else {
            results = []
            searchedQuery = ""
            return
        }
        isSearching = true
        async let counts: Void = loadPopularity()
        let hits = await Task.detached {
            BrewKind.allCases.flatMap { kind in client.search(text, kind: kind).map { BrewSearchHit(kind: kind, name: $0) } }
        }.value
        await counts
        results = BrewSearchHit.ranked(hits, query: text, popularity: popularity)
        searchedQuery = text
        isSearching = false
    }

    func details(for hit: BrewSearchHit) async -> BrewPackage? {
        guard let client else { return nil }
        return await Task.detached { client.info(hit.name, kind: hit.kind) }.value
    }

    @discardableResult
    func run(_ action: BrewAction, then completion: (@MainActor () async -> Void)? = nil) -> Bool {
        guard let client else { return false }
        guard !isBusy else {
            message = "Wait until “\(job?.action.title ?? "")” finishes."
            return false
        }
        let process = BrewProcess()
        message = ""
        job = BrewJob(action: action, commandLine: action.commandLine(brew: client.path))
        self.process = process
        self.completion = completion
        do {
            try process.start(client.path, action.arguments, output: { [weak self] text in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.job?.log.append(text) } }
            }, finished: { [weak self] status in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(status) } }
            })
        } catch {
            job?.log.append(error.localizedDescription + "\n")
            finish(-1)
        }
        return true
    }

    func cancelJob() {
        guard isBusy else { return }
        job?.isCancelling = true
        process?.cancel()
    }

    func dismissJob() {
        if !isBusy { job = nil }
    }

    func installHomebrew() {
        if !TerminalScript.open(TerminalScript.homebrewInstaller) { message = "Could not open Terminal." }
    }

    private func finish(_ status: Int32) {
        job?.status = status
        process = nil
        let completion = completion
        self.completion = nil
        Task {
            await refresh()
            await completion?()
        }
    }

    private func loadPopularity() async {
        guard popularity.isEmpty else { return }
        var merged: [String: Int] = [:]
        for (kind, url) in Self.analytics {
            guard let data = await DownloadCache.standard.data(from: url, name: "brew-\(kind.rawValue)-30d.json", maxAge: Self.analyticsLife),
                  let counts = BrewJSON.popularity(from: data) else { continue }
            for (name, count) in counts { merged["\(kind.rawValue):\(name)"] = count }
        }
        popularity = merged
    }
}
