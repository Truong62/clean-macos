import Foundation

struct RuntimeScanner {
    private struct Location {
        let name: String
        let source: String
        let root: String
        let binary: String
    }

    private static let versionedLocations: [Location] = [
        Location(name: "Node.js", source: "nvm", root: "~/.nvm/versions/node", binary: "bin/node"),
        Location(name: "Node.js", source: "fnm", root: "~/.local/share/fnm/node-versions", binary: "installation/bin/node"),
        Location(name: "Node.js", source: "fnm", root: "~/Library/Application Support/fnm/node-versions", binary: "installation/bin/node"),
        Location(name: "Node.js", source: "Volta", root: "~/.volta/tools/image/node", binary: "bin/node"),
        Location(name: "Node.js", source: "nodenv", root: "~/.nodenv/versions", binary: "bin/node"),
        Location(name: "Node.js", source: "n", root: "/usr/local/n/versions/node", binary: "bin/node"),
        Location(name: "Node.js", source: "asdf", root: "~/.asdf/installs/nodejs", binary: "bin/node"),
        Location(name: "Node.js", source: "mise", root: "~/.local/share/mise/installs/node", binary: "bin/node"),
        Location(name: "Python", source: "pyenv", root: "~/.pyenv/versions", binary: "bin/python3"),
        Location(name: "Python", source: "asdf", root: "~/.asdf/installs/python", binary: "bin/python3"),
        Location(name: "Python", source: "mise", root: "~/.local/share/mise/installs/python", binary: "bin/python3"),
        Location(name: "Python", source: "python.org", root: "/Library/Frameworks/Python.framework/Versions", binary: "bin/python3"),
        Location(name: "Ruby", source: "rbenv", root: "~/.rbenv/versions", binary: "bin/ruby"),
        Location(name: "Ruby", source: "asdf", root: "~/.asdf/installs/ruby", binary: "bin/ruby"),
        Location(name: "Ruby", source: "mise", root: "~/.local/share/mise/installs/ruby", binary: "bin/ruby"),
        Location(name: "Go", source: "asdf", root: "~/.asdf/installs/golang", binary: "go/bin/go"),
        Location(name: "Go", source: "mise", root: "~/.local/share/mise/installs/go", binary: "bin/go"),
        Location(name: "Java", source: "JDK", root: "/Library/Java/JavaVirtualMachines", binary: "Contents/Home/bin/java"),
        Location(name: "Java", source: "JDK", root: "~/Library/Java/JavaVirtualMachines", binary: "Contents/Home/bin/java"),
        Location(name: "Rust", source: "rustup", root: "~/.rustup/toolchains", binary: "bin/rustc"),
    ]

    let home: URL
    let systemRoot: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, systemRoot: URL = URL(fileURLWithPath: "/")) {
        self.home = home
        self.systemRoot = systemRoot
    }

    func scan() -> [DevTool] {
        let found = Self.versionedLocations.flatMap(versions) + [goInstaller(), standalone("Bun", "~/.bun", "bin/bun"),
                                                                 standalone("Deno", "~/.deno", "bin/deno")].compactMap { $0 }
        var seen = Set<String>()
        let unique = found.filter { seen.insert(URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path).inserted }
        return DevToolVersion.sortedByNameThenNewest(unique)
    }

    static func parseShellProbe(_ output: String) -> [String: String] {
        output.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            guard line.hasPrefix("@@"), let equals = line.firstIndex(of: "=") else { return }
            let path = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { result[String(line.dropFirst(2)[..<equals])] = path }
        }
    }

    static func removingLinkedDuplicates(_ tools: [DevTool], resolve: (String) -> String) -> [DevTool] {
        let roots = tools.map { resolve($0.path) }
        return tools.enumerated().filter { index, _ in
            !roots.enumerated().contains { other, root in other != index && roots[index].hasPrefix(root + "/") }
        }.map(\.element)
    }

    static func markActive(_ tools: [DevTool], commandPaths: [String], resolve: (String) -> String) -> [DevTool] {
        let resolved = commandPaths.map(resolve)
        return tools.map { tool in
            var tool = tool
            let root = resolve(tool.path) + "/"
            tool.isActive = resolved.contains { $0.hasPrefix(root) }
            return tool
        }
    }

    private func url(_ template: String) -> URL {
        template.hasPrefix("~/")
            ? home.appendingPathComponent(String(template.dropFirst(2)))
            : systemRoot.appendingPathComponent(String(template.dropFirst()))
    }

    private func versions(at location: Location) -> [DevTool] {
        let root = url(location.root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && $0 != "Current" }.compactMap { name in
            let dir = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(location.binary).path) else { return nil }
            let version = location.name == "Java" ? Self.javaVersion(dir) ?? name : Self.cleanVersion(name)
            return DevTool(name: location.name, version: version, source: location.source, path: dir.path,
                           kind: .runtime, removal: Self.trashRemoval(dir.path))
        }
    }

    private func goInstaller() -> DevTool? {
        let dir = url("/usr/local/go")
        guard let text = try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8),
              let first = text.split(whereSeparator: \.isNewline).first else { return nil }
        return DevTool(name: "Go", version: Self.cleanVersion(String(first)), source: "Go installer", path: dir.path,
                       kind: .runtime, removal: Self.trashRemoval(dir.path))
    }

    private func standalone(_ name: String, _ root: String, _ binary: String) -> DevTool? {
        let dir = url(root)
        let executable = dir.appendingPathComponent(binary).path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let output = CommandRunner.run(executable, ["--version"]).output
        let version = output.split(whereSeparator: \.isNewline).first.map { Self.cleanVersion(String($0)) } ?? "?"
        return DevTool(name: name, version: version, source: "\(name.lowercased()) installer", path: dir.path,
                       kind: .runtime, removal: Self.trashRemoval(dir.path))
    }

    static func cleanVersion(_ raw: String) -> String {
        let lowered = raw.lowercased()
        for prefix in ["deno ", "go", "v"] where lowered.hasPrefix(prefix) {
            return String(raw.dropFirst(prefix.count)).components(separatedBy: " ").first ?? raw
        }
        return raw
    }

    static func javaVersion(_ jdk: URL) -> String? {
        guard let release = try? String(contentsOf: jdk.appendingPathComponent("Contents/Home/release"), encoding: .utf8) else { return nil }
        let line = release.split(whereSeparator: \.isNewline).first { $0.hasPrefix("JAVA_VERSION=") }
        return line.map { $0.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }

    static func trashRemoval(_ path: String) -> DevToolRemoval {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent)
            ? .trash(path)
            : .unavailable("Needs administrator rights. Remove it in Terminal with: sudo rm -rf \"\(path)\"")
    }
}

enum HomebrewInventory {
    private static let runtimeNames = ["node": "Node.js", "python": "Python", "ruby": "Ruby", "go": "Go", "openjdk": "Java",
                                       "rust": "Rust", "deno": "Deno", "bun": "Bun", "php": "PHP"]

    private struct Info: Decodable {
        let formulae: [Formula]
        let casks: [Cask]
    }

    private struct Formula: Decodable {
        struct Versions: Decodable { let stable: String? }
        struct Installed: Decodable {
            let version: String
            let installed_on_request: Bool?
        }
        let name: String
        let desc: String?
        let homepage: String?
        let versions: Versions
        let installed: [Installed]
    }

    private struct Cask: Decodable {
        let token: String
        let desc: String?
        let homepage: String?
        let installed: String?
        let version: String?
    }

    static func parse(_ data: Data, prefix: String) throws -> [DevTool] {
        let info = try JSONDecoder().decode(Info.self, from: data)
        let brew = "\(prefix)/bin/brew"
        let formulae = info.formulae.compactMap { formula -> DevTool? in
            guard let installed = formula.installed.last else { return nil }
            var tool = DevTool(name: formula.name, version: installed.version, source: "Homebrew",
                               path: "\(prefix)/Cellar/\(formula.name)/\(installed.version)", kind: .homebrew,
                               removal: .command(path: brew, arguments: ["uninstall", formula.name]))
            tool.summary = formula.desc ?? ""
            tool.homepage = formula.homepage.flatMap(URL.init(string:))
            tool.isDependency = installed.installed_on_request == false
            if let stable = formula.versions.stable, DevToolVersion.isOrderedBefore(installed.version, stable) {
                tool.note = "Update available: \(stable)"
                tool.updateCommand = ShellCommand(path: brew, arguments: ["upgrade", formula.name])
            }
            return tool
        }
        let casks = info.casks.map { cask in
            let installed = cask.installed ?? cask.version ?? "?"
            var tool = DevTool(name: cask.token, version: caskVersion(installed), source: "Homebrew Cask",
                               path: "\(prefix)/Caskroom/\(cask.token)", kind: .homebrew,
                               removal: .command(path: brew, arguments: ["uninstall", "--cask", cask.token]))
            tool.summary = cask.desc ?? ""
            tool.homepage = cask.homepage.flatMap(URL.init(string:))
            if let latest = cask.version, latest != "latest", latest != installed {
                tool.note = "Update available: \(caskVersion(latest))"
                tool.updateCommand = ShellCommand(path: brew, arguments: ["upgrade", "--cask", "--greedy", cask.token])
            }
            return tool
        }
        return (formulae + casks).sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func runtimes(from brew: [DevTool]) -> [DevTool] {
        let runtimes = brew.compactMap { tool -> DevTool? in
            guard tool.source == "Homebrew", let display = runtimeName(tool.name) else { return nil }
            var runtime = DevTool(name: display, version: tool.version, source: "Homebrew", path: tool.path,
                                  kind: .runtime, removal: tool.removal)
            runtime.summary = tool.summary
            runtime.homepage = tool.homepage
            runtime.note = tool.note
            runtime.updateCommand = tool.updateCommand
            return runtime
        }
        return DevToolVersion.sortedByNameThenNewest(runtimes)
    }

    private static func caskVersion(_ raw: String) -> String {
        raw.split(separator: ",").first.map(String.init) ?? raw
    }

    private static func runtimeName(_ formula: String) -> String? {
        let base = formula.split(separator: "@").first.map(String.init) ?? formula
        return runtimeNames[base]
    }
}

enum GlobalPackageScanner {
    private static let bundledWithNode: Set<String> = ["npm", "corepack"]
    private static let rustupProxies: Set<String> = ["cargo", "cargo-clippy", "cargo-fmt", "cargo-miri", "clippy-driver", "rls",
                                                     "rust-analyzer", "rust-gdb", "rust-gdbgui", "rust-lldb", "rustc", "rustdoc",
                                                     "rustfmt", "rustup"]

    private struct PackageJSON: Decodable {
        let name: String?
        let version: String?
    }

    static func nodePackages(in nodeModules: URL, source: String, binDirectory: String) -> [DevTool] {
        packageDirectories(in: nodeModules).compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
                  let package = try? JSONDecoder().decode(PackageJSON.self, from: data),
                  let name = package.name else { return nil }
            let removal: DevToolRemoval = bundledWithNode.contains(name)
                ? .unavailable("Bundled with Node.js")
                : .command(path: "/usr/bin/env", arguments: ["PATH=\(binDirectory):/usr/bin:/bin", "\(binDirectory)/npm", "uninstall", "-g", name])
            return DevTool(name: name, version: package.version ?? "?", source: source, path: dir.path, kind: .package, removal: removal)
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func packageDirectories(in nodeModules: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: nodeModules.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.flatMap { name -> [URL] in
            let dir = nodeModules.appendingPathComponent(name)
            guard name.hasPrefix("@") else { return [dir] }
            let scoped = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return scoped.filter { !$0.hasPrefix(".") }.map { dir.appendingPathComponent($0) }
        }
    }

    private struct OutdatedEntry: Decodable {
        let latest: String?
        let location: String?
    }

    static func parseNpmOutdated(_ json: String) -> [String: String] {
        guard let entries = try? JSONDecoder().decode([String: OutdatedEntry].self, from: Data(json.utf8)) else { return [:] }
        return entries.values.reduce(into: [:]) { result, entry in
            if let location = entry.location, let latest = entry.latest { result[location] = latest }
        }
    }

    static func npmBinDirectory(forPackageAt path: String) -> String? {
        guard let range = path.range(of: "/lib/node_modules/") else { return nil }
        return path[..<range.lowerBound] + "/bin"
    }

    static func applyingNpmUpdates(_ tools: [DevTool], latestByLocation: [String: String]) -> [DevTool] {
        tools.map { tool in
            guard let latest = latestByLocation[tool.path], latest != tool.version,
                  let bin = npmBinDirectory(forPackageAt: tool.path) else { return tool }
            var tool = tool
            tool.note = "Update available: \(latest)"
            tool.updateCommand = ShellCommand(path: "/usr/bin/env",
                                              arguments: ["PATH=\(bin):/usr/bin:/bin", "\(bin)/npm", "install", "-g", "\(tool.name)@latest"])
            return tool
        }
    }

    static func binaries(in directory: URL, source: String, excluding: Set<String> = []) -> [DevTool] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { !$0.hasPrefix(".") && !excluding.contains($0) }.sorted().map { name in
            let path = directory.appendingPathComponent(name).path
            return DevTool(name: name, version: "—", source: source, path: path, kind: .package, removal: .trash(path))
        }
    }

    static func scan(runtimes: [DevTool], home: URL, brewPrefix: String?) -> [DevTool] {
        let nodeInstalls = runtimes.filter { $0.name == "Node.js" && $0.source != "Homebrew" }
        var packages = nodeInstalls.flatMap { node in
            let root = URL(fileURLWithPath: node.path)
            let base = node.source == "fnm" ? root.appendingPathComponent("installation") : root
            return nodePackages(in: base.appendingPathComponent("lib/node_modules"),
                                source: "npm · Node.js \(node.version) (\(node.source))",
                                binDirectory: base.appendingPathComponent("bin").path)
        }
        if let brewPrefix {
            packages += nodePackages(in: URL(fileURLWithPath: "\(brewPrefix)/lib/node_modules"), source: "npm · Homebrew Node.js",
                                     binDirectory: "\(brewPrefix)/bin")
        }
        let bunGlobals = nodePackages(in: home.appendingPathComponent(".bun/install/global/node_modules"), source: "bun",
                                      binDirectory: home.appendingPathComponent(".bun/bin").path)
            .map { package in
                DevTool(name: package.name, version: package.version, source: "bun", path: package.path, kind: .package,
                        removal: .command(path: "/usr/bin/env", arguments: ["PATH=\(home.path)/.bun/bin:/usr/bin:/bin",
                                                                            "\(home.path)/.bun/bin/bun", "remove", "-g", package.name]))
            }
        return packages + bunGlobals
            + binaries(in: home.appendingPathComponent("go/bin"), source: "go install")
            + binaries(in: home.appendingPathComponent(".cargo/bin"), source: "cargo install", excluding: rustupProxies)
    }
}

struct DevToolsService: Sendable {
    private static let brewPrefixes = ["/opt/homebrew", "/usr/local"]
    private static let probedCommands = ["node", "python3", "ruby", "go", "java", "rustc", "bun", "deno", "php"]
    private static let shellTimeout: TimeInterval = 8

    func list() async -> [DevTool] {
        await Task.detached(priority: .utility) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            async let commands = Self.loginShellCommands()
            let brewPrefix = Self.brewPrefixes.first { FileManager.default.isExecutableFile(atPath: "\($0)/bin/brew") }
            let brew = brewPrefix.flatMap { prefix -> [DevTool]? in
                let result = CommandRunner.run("\(prefix)/bin/brew", ["info", "--json=v2", "--installed"])
                return try? HomebrewInventory.parse(Data(result.output.utf8), prefix: prefix)
            } ?? []
            let resolve = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
            let runtimes = RuntimeScanner.removingLinkedDuplicates(
                DevToolVersion.sortedByNameThenNewest(RuntimeScanner().scan() + HomebrewInventory.runtimes(from: brew)), resolve: resolve)
            let active = RuntimeScanner.markActive(runtimes, commandPaths: Array(await commands.values), resolve: resolve)
            return active + brew + GlobalPackageScanner.scan(runtimes: runtimes, home: home, brewPrefix: brewPrefix)
        }.value
    }

    func size(of tool: DevTool) async -> Int64 {
        await Task.detached(priority: .background) {
            ScannerService.calculateDirSize(path: tool.path, timeout: 20)
        }.value
    }

    func remove(_ tool: DevTool) async throws {
        try await Task.detached(priority: .userInitiated) {
            switch tool.removal {
            case .trash(let path):
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            case .command(let path, let arguments):
                try Self.run(ShellCommand(path: path, arguments: arguments))
            case .unavailable(let reason):
                throw PortsJobsError.commandFailed(reason)
            }
        }.value
    }

    func update(_ tool: DevTool) async throws {
        guard let command = tool.updateCommand else { throw PortsJobsError.commandFailed("\(tool.name) is already up to date.") }
        try await Task.detached(priority: .userInitiated) { try Self.run(command) }.value
    }

    func checkPackageUpdates(_ tools: [DevTool]) async -> [DevTool] {
        await Task.detached(priority: .utility) {
            let bins = Set(tools.filter { $0.kind == .package }.compactMap { GlobalPackageScanner.npmBinDirectory(forPackageAt: $0.path) })
            let latest = bins.filter { FileManager.default.isExecutableFile(atPath: "\($0)/npm") }.reduce(into: [String: String]()) { result, bin in
                let output = CommandRunner.run("/usr/bin/env", ["PATH=\(bin):/usr/bin:/bin", "\(bin)/npm", "outdated", "-g", "--json"]).output
                result.merge(GlobalPackageScanner.parseNpmOutdated(output)) { first, _ in first }
            }
            return GlobalPackageScanner.applyingNpmUpdates(tools, latestByLocation: latest)
        }.value
    }

    private static func run(_ command: ShellCommand) throws {
        let result = CommandRunner.run(command.path, command.arguments)
        guard result.status == 0 else {
            let message = [result.error, result.output].first { !$0.isEmpty } ?? "exit \(result.status)"
            throw PortsJobsError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func loginShellCommands() async -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let script = probedCommands.map { "echo \"@@\($0)=$(command -v \($0))\"" }.joined(separator: "; ")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", script]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        DispatchQueue.global().asyncAfter(deadline: .now() + shellTimeout) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RuntimeScanner.parseShellProbe(String(decoding: data, as: UTF8.self))
    }
}
