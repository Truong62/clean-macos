import Foundation

enum BrewKind: String, CaseIterable, Identifiable, Sendable {
    case formula, cask

    var id: String { rawValue }
    var flag: String { "--\(rawValue)" }
    var title: String { self == .cask ? "Cask" : "Formula" }
}

enum BrewFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case casks = "Casks"
    case formulae = "Formulae"

    var id: String { rawValue }

    func includes(_ kind: BrewKind) -> Bool {
        switch self {
        case .all: true
        case .casks: kind == .cask
        case .formulae: kind == .formula
        }
    }
}

struct BrewPackage: Identifiable, Hashable, Sendable {
    let kind: BrewKind
    let name: String
    var fullName: String
    var summary = ""
    var homepage: URL?
    var installedVersion: String?
    var latestVersion = ""
    var isRequested = true
    var isPinned = false
    var dependencies: [String] = []
    var aliases: [String] = []
    var apps: [String] = []
    var bundleIDs: [String] = []

    init(kind: BrewKind, name: String, fullName: String? = nil) {
        self.kind = kind
        self.name = name
        self.fullName = fullName ?? name
    }

    var id: String { "\(kind.rawValue):\(fullName)" }
    var isInstalled: Bool { installedVersion != nil }
}

struct BrewOutdated: Equatable, Sendable {
    let kind: BrewKind
    let name: String
    let installedVersions: [String]
    let currentVersion: String
    let isPinned: Bool

    var key: String { "\(kind.rawValue):\(name)" }

    static func byToken(_ items: [BrewOutdated]) -> [String: BrewOutdated] {
        Dictionary(items.map { (String($0.name.split(separator: "/").last ?? Substring($0.name)), $0) }, uniquingKeysWith: { first, _ in first })
    }
}

struct BrewSearchHit: Identifiable, Hashable, Sendable {
    let kind: BrewKind
    let name: String

    var id: String { "\(kind.rawValue):\(name)" }

    static func ranked(_ hits: [BrewSearchHit], query: String, popularity: [String: Int]) -> [BrewSearchHit] {
        let wanted = query.lowercased()
        func rank(_ hit: BrewSearchHit) -> (Int, Int, String) {
            (hit.name.lowercased() == wanted ? 0 : 1, -(popularity[hit.id] ?? 0), hit.name)
        }
        return hits.sorted { rank($0) < rank($1) }
    }
}

enum BrewJSON {
    static func packages(from data: Data) -> [BrewPackage]? {
        guard let info = try? JSONDecoder().decode(InfoList.self, from: data) else { return nil }
        return (info.formulae ?? []).map(\.package) + (info.casks ?? []).map(\.package)
    }

    static func catalog(from data: Data) -> [BrewPackage]? {
        (try? JSONDecoder().decode([Cask].self, from: data))?.map(\.package)
    }

    static func outdated(from text: String) -> [BrewOutdated]? {
        guard let list = decode(OutdatedList.self, fromNoisy: text) else { return nil }
        return list.formulae.map { $0.item(.formula) } + list.casks.map { $0.item(.cask) }
    }

    static func searchResults(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let name = words.first, name.allSatisfy({ $0.isLetter || $0.isNumber || "@+._/-".contains($0) }),
                  words.dropFirst().allSatisfy({ !$0.contains(where: \.isLetter) }) else { return nil }
            return String(name)
        }
    }

    static func popularity(from data: Data) -> [String: Int]? {
        guard let analytics = try? JSONDecoder().decode(Analytics.self, from: data) else { return nil }
        return analytics.items.reduce(into: [:]) { counts, item in
            guard let name = item.name.split(separator: " ").first else { return }
            counts[String(name), default: 0] += item.count
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, fromNoisy text: String) -> T? {
        let bytes = Array(text.utf8)
        var start = bytes.startIndex
        while let open = bytes[start...].firstIndex(of: UInt8(ascii: "{")) {
            if let close = closingBrace(in: bytes, from: open), let value = try? JSONDecoder().decode(T.self, from: Data(bytes[open...close])) {
                return value
            }
            start = open + 1
        }
        return nil
    }

    static func bundleID(fromPath path: String) -> String? {
        var name = (path as NSString).lastPathComponent
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        guard name.filter({ $0 == "." }).count >= 2, !name.contains("*"), !name.contains(" ") else { return nil }
        return name
    }

    private static func closingBrace(in bytes: [UInt8], from open: Int) -> Int? {
        var depth = 0
        var isInString = false
        var isEscaped = false
        for index in open..<bytes.count {
            let byte = bytes[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if byte == UInt8(ascii: "\\") {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    isInString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                isInString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    private struct InfoList: Decodable {
        let formulae: [Formula]?
        let casks: [Cask]?
    }

    private struct Formula: Decodable {
        let package: BrewPackage

        private enum Key: String, CodingKey {
            case name, desc, homepage, versions, installed, pinned, dependencies, aliases, oldnames
            case fullName = "full_name"
        }

        private struct Versions: Decodable {
            let stable: String?
        }

        private struct Installed: Decodable {
            struct Dependency: Decodable {
                let fullName: String

                private enum CodingKeys: String, CodingKey {
                    case fullName = "full_name"
                }
            }

            let version: String
            let isRequested: Bool?
            let runtimeDependencies: [Dependency]?

            private enum CodingKeys: String, CodingKey {
                case version
                case isRequested = "installed_on_request"
                case runtimeDependencies = "runtime_dependencies"
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let installed = (container.loose(.installed) as [Installed]?)?.last
            var package = BrewPackage(kind: .formula, name: try container.decode(String.self, forKey: .name), fullName: container.loose(.fullName))
            package.summary = container.loose(.desc) ?? ""
            package.homepage = (container.loose(.homepage) as String?).flatMap(URL.init(string:))
            package.installedVersion = installed?.version
            package.latestVersion = (container.loose(.versions) as Versions?)?.stable ?? ""
            package.isRequested = installed?.isRequested ?? true
            package.isPinned = container.loose(.pinned) ?? false
            package.dependencies = installed?.runtimeDependencies?.map(\.fullName) ?? container.loose(.dependencies) ?? []
            package.aliases = (container.loose(.aliases) ?? []) + (container.loose(.oldnames) ?? [])
            self.package = package
        }
    }

    private struct Cask: Decodable {
        let package: BrewPackage

        private enum Key: String, CodingKey {
            case token, name, desc, homepage, version, installed, artifacts
            case fullToken = "full_token"
            case dependsOn = "depends_on"
        }

        private struct DependsOn: Decodable {
            let formula: Strings?
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            let artifacts: [Artifact] = container.loose(.artifacts) ?? []
            var package = BrewPackage(kind: .cask, name: try container.decode(String.self, forKey: .token), fullName: container.loose(.fullToken))
            package.summary = container.loose(.desc) ?? (container.loose(.name) as [String]?)?.first ?? ""
            package.homepage = (container.loose(.homepage) as String?).flatMap(URL.init(string:))
            package.installedVersion = container.loose(.installed)
            package.latestVersion = container.loose(.version) ?? ""
            package.dependencies = (container.loose(.dependsOn) as DependsOn?)?.formula?.values ?? []
            package.apps = artifacts.flatMap(\.apps)
            package.bundleIDs = artifacts.flatMap(\.bundleIDs)
            self.package = package
        }
    }

    private struct Artifact: Decodable {
        var apps: [String] = []
        var bundleIDs: [String] = []

        private enum Key: String, CodingKey {
            case app, target, uninstall, zap
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Key.self) else { return }
            let entries: [Entry] = container.loose(.app) ?? []
            if let source = entries.first?.text {
                let target = entries.dropFirst().compactMap(\.target).first ?? container.loose(.target) ?? source
                apps = [(target as NSString).lastPathComponent]
            }
            let stanzas: [Stanza] = (container.loose(.uninstall) ?? []) + (container.loose(.zap) ?? [])
            bundleIDs = stanzas.flatMap(\.bundleIDs)
        }
    }

    private struct Entry: Decodable {
        var text: String?
        var target: String?

        private enum Key: String, CodingKey {
            case target
        }

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                text = value
            } else if let container = try? decoder.container(keyedBy: Key.self) {
                target = container.loose(.target)
            }
        }
    }

    private struct Stanza: Decodable {
        var bundleIDs: [String] = []

        private enum Key: String, CodingKey {
            case quit, trash, delete, rmdir
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Key.self) else { return }
            let quits = (container.loose(.quit) as Strings?)?.values ?? []
            let paths = [Key.trash, .delete, .rmdir].flatMap { (container.loose($0) as Strings?)?.values ?? [] }
            bundleIDs = quits + paths.compactMap(BrewJSON.bundleID(fromPath:))
        }
    }

    private struct Strings: Decodable {
        var values: [String] = []

        init(from decoder: Decoder) throws {
            if let value = try? decoder.singleValueContainer().decode(String.self) {
                values = [value]
            } else if let list = try? decoder.singleValueContainer().decode([Loose].self) {
                values = list.compactMap(\.text)
            }
        }
    }

    private struct Loose: Decodable {
        var text: String?

        init(from decoder: Decoder) throws {
            text = try? decoder.singleValueContainer().decode(String.self)
        }
    }

    private struct OutdatedList: Decodable {
        let formulae: [OutdatedEntry]
        let casks: [OutdatedEntry]
    }

    private struct OutdatedEntry: Decodable {
        let name: String
        let installedVersions: [String]?
        let currentVersion: String?
        let pinned: Bool?

        private enum CodingKeys: String, CodingKey {
            case name, pinned
            case installedVersions = "installed_versions"
            case currentVersion = "current_version"
        }

        func item(_ kind: BrewKind) -> BrewOutdated {
            BrewOutdated(kind: kind, name: name, installedVersions: installedVersions ?? [], currentVersion: currentVersion ?? "",
                         isPinned: pinned ?? false)
        }
    }

    private struct Analytics: Decodable {
        let items: [AnalyticsItem]
    }

    private struct AnalyticsItem: Decodable {
        let name: String
        let count: Int

        private enum Key: String, CodingKey {
            case formula, cask, count
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            name = container.loose(.formula) ?? container.loose(.cask) ?? ""
            count = container.loose(.count) ?? Int((container.loose(.count) as String? ?? "").filter(\.isNumber)) ?? 0
        }
    }
}

private extension KeyedDecodingContainer {
    func loose<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

struct BrewGroup: Identifiable, Equatable, Sendable {
    let package: BrewPackage
    let dependencies: [BrewPackage]

    var id: String { package.id }
}

struct BrewTree: Equatable, Sendable {
    let groups: [BrewGroup]
    let leftovers: [BrewPackage]

    init(_ packages: [BrewPackage]) {
        let installed = packages.filter { $0.kind == .formula }
        var formulae: [String: BrewPackage] = [:]
        for package in installed {
            for alias in package.aliases { formulae[alias] = package }
        }
        for package in installed {
            formulae[package.name] = package
            formulae[package.fullName] = package
        }
        let groups = packages.filter { $0.kind == .cask || $0.isRequested }.map { root in
            BrewGroup(package: root, dependencies: Self.dependencies(of: root, in: formulae))
        }
        let needed = Set(groups.flatMap { $0.dependencies.map(\.id) })
        self.groups = groups
        leftovers = packages.filter { $0.kind == .formula && !$0.isRequested && !needed.contains($0.id) }
    }

    private static func dependencies(of root: BrewPackage, in formulae: [String: BrewPackage]) -> [BrewPackage] {
        var found: [String: BrewPackage] = [:]
        var queue = root.dependencies
        while let name = queue.popLast() {
            guard let package = formulae[name], package.id != root.id, found[package.id] == nil else { continue }
            found[package.id] = package
            queue += package.dependencies
        }
        return found.values.filter { !$0.isRequested }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum BrewAction: Hashable, Sendable {
    case install(BrewKind, String)
    case uninstall(BrewKind, String)
    case upgrade(BrewKind, String)
    case upgradeAll
    case update
    case trustTap(String)
    case upgradeApps([String])

    var arguments: [String] {
        switch self {
        case .install(let kind, let name): ["install", kind.flag, name]
        case .uninstall(let kind, let name): ["uninstall", kind.flag, name]
        case .upgrade(let kind, let name): ["upgrade", kind.flag, name]
        case .upgradeAll: ["upgrade"]
        case .update: ["update"]
        case .trustTap(let tap): ["trust", "--tap", tap]
        case .upgradeApps(let tokens): ["upgrade", "--cask", "--greedy"] + tokens
        }
    }

    var title: String {
        switch self {
        case .install(_, let name): "Install \(name)"
        case .uninstall(_, let name): "Uninstall \(name)"
        case .upgrade(_, let name): "Upgrade \(name)"
        case .upgradeAll: "Upgrade everything"
        case .update: "Update Homebrew"
        case .trustTap(let tap): "Trust \(tap)"
        case .upgradeApps(let tokens): tokens.count == 1 ? "Upgrade \(tokens[0])" : "Upgrade \(tokens.count) apps"
        }
    }

    var confirmTitle: String {
        switch self {
        case .install: "Install"
        case .uninstall: "Uninstall"
        case .upgrade, .upgradeApps: "Upgrade"
        case .upgradeAll: "Upgrade All"
        case .update: "Update"
        case .trustTap: "Trust"
        }
    }

    var isDestructive: Bool {
        if case .uninstall = self { return true }
        return false
    }

    func commandLine(brew: String) -> String {
        ([brew] + arguments).map(Shell.quoted).joined(separator: " ")
    }
}

enum Shell {
    private static let safe = Set("@%+=:,./_-")

    static func quoted(_ word: String) -> String {
        guard word.isEmpty || !word.allSatisfy({ $0.isLetter || $0.isNumber || safe.contains($0) }) else { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct BrewLog: Equatable, Sendable {
    static let lineLimit = 1000

    private(set) var lines: [String] = []
    private(set) var phase = ""
    private(set) var percent: Double?
    private var partial = ""

    var text: String {
        let tail = Self.visible(partial)
        return (tail.isEmpty ? lines : lines + [tail]).joined(separator: "\n")
    }

    mutating func append(_ chunk: String) {
        var pieces = (partial + chunk).components(separatedBy: "\n")
        partial = pieces.removeLast()
        for piece in pieces { add(piece) }
        if let value = Self.percent(in: partial) { percent = value }
        if partial.contains("\r") { partial = Self.visible(partial) + (partial.hasSuffix("\r") ? "\r" : "") }
    }

    static func visible(_ raw: String) -> String {
        let plain = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return plain.split(separator: "\r").last.map(String.init) ?? ""
    }

    static func percent(in line: String) -> Double? {
        guard let match = line.matches(of: #/(\d{1,3}(?:\.\d+)?)\s?%/#).last, let value = Double(match.1), value <= 100 else { return nil }
        return value
    }

    private mutating func add(_ raw: String) {
        let line = Self.visible(raw)
        lines.append(line)
        if lines.count > Self.lineLimit { lines.removeFirst(lines.count - Self.lineLimit) }
        if line.hasPrefix("==> ") {
            phase = String(line.dropFirst(4))
            percent = nil
        } else if let value = Self.percent(in: raw) {
            percent = value
        }
    }
}

enum BrewSignals {
    static let passwordHints = ["a terminal is required to read the password", "a password is required", "no tty present", "askpass", "password:"]

    static func needsPassword(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return passwordHints.contains { lowered.contains($0) }
    }

    static func untrustedTap(_ output: String) -> String? {
        let patterns = [#/untrusted tap ([\w.@+-]+/[\w.@+-]+)/#, #/Skipping ([\w.@+-]+/[\w.@+-]+) because it is not trusted/#]
        for pattern in patterns {
            if let match = output.firstMatch(of: pattern) {
                return String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
        }
        return nil
    }
}

struct BrewJob: Identifiable, Sendable {
    let id = UUID()
    let action: BrewAction
    let commandLine: String
    var log = BrewLog()
    var status: Int32?
    var isCancelling = false

    var isRunning: Bool { status == nil }
    var succeeded: Bool { status == 0 }
    var failed: Bool { (status ?? 0) != 0 && !isCancelling }
    var untrustedTap: String? { failed ? BrewSignals.untrustedTap(log.text) : nil }
    var needsTerminal: Bool { failed && BrewSignals.needsPassword(log.text) }

    var statusText: String {
        guard let status else { return isCancelling ? "Stopping…" : "Running…" }
        if isCancelling { return "Cancelled" }
        return status == 0 ? "Done" : "Failed with exit code \(status)"
    }
}

enum TerminalScript {
    static let homebrewInstaller = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    static func contents(for command: String) -> String {
        "#!/bin/bash\nrm -f \"$0\"\n\(command)\n"
    }
}
