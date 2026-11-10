import Foundation

enum AppVersion {
    private enum Token: Equatable {
        case number(String)
        case text(String)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = tokens(lhs)
        let right = tokens(rhs)
        for index in 0..<max(left.count, right.count) {
            let result = compare(index < left.count ? left[index] : nil, index < right.count ? right[index] : nil)
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }

    static func caskVersion(_ raw: String) -> String {
        raw.split(separator: ",").first.map(String.init) ?? raw
    }

    static func label(_ version: String, build: String, against other: String) -> String {
        version == other && build != version ? "\(version) (\(build))" : version
    }

    static func installed(_ version: String, build: String, matching latest: String) -> String {
        latest.hasPrefix(version + ".") && build.hasPrefix(version + ".") ? build : version
    }

    private static func tokens(_ version: String) -> [Token] {
        var text = Substring(version.trimmingCharacters(in: .whitespaces))
        if let first = text.first, first == "v" || first == "V", text.dropFirst().first?.isNumber == true { text = text.dropFirst() }
        var tokens: [Token] = []
        var current = ""
        var isDigits = false
        for character in text {
            let digit = character.isASCII && character.isNumber
            if digit || character.isLetter {
                if !current.isEmpty && digit != isDigits {
                    tokens.append(isDigits ? .number(current) : .text(current.lowercased()))
                    current = ""
                }
                isDigits = digit
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(isDigits ? .number(current) : .text(current.lowercased()))
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(isDigits ? .number(current) : .text(current.lowercased())) }
        return tokens
    }

    private static func compare(_ lhs: Token?, _ rhs: Token?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.number(left)?, .number(right)?): compareDigits(left, right)
        case let (.text(left)?, .text(right)?): left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
        case (.number?, .text?): .orderedDescending
        case (.text?, .number?): .orderedAscending
        case let (.number(left)?, nil): isZero(left) ? .orderedSame : .orderedDescending
        case let (nil, .number(right)?): isZero(right) ? .orderedSame : .orderedAscending
        case (.text?, nil): .orderedAscending
        case (nil, .text?): .orderedDescending
        case (nil, nil): .orderedSame
        }
    }

    private static func compareDigits(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.drop { $0 == "0" }
        let right = rhs.drop { $0 == "0" }
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        return left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
    }

    private static func isZero(_ digits: String) -> Bool {
        digits.allSatisfy { $0 == "0" }
    }
}

struct AppBundle: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let bundleID: String
    let version: String
    let build: String
    var feed: String?
    var isAppStore = false
    var electronConfig: String?

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }

    static func read(at url: URL) -> AppBundle? {
        let contents = url.appendingPathComponent("Contents")
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let bundleID = text(info["CFBundleIdentifier"]) else { return nil }
        let build = text(info["CFBundleVersion"])
        guard let version = text(info["CFBundleShortVersionString"]) ?? build else { return nil }
        var app = AppBundle(path: url.path, name: url.deletingPathExtension().lastPathComponent, bundleID: bundleID, version: version, build: build ?? version)
        app.feed = text(info["SUFeedURL"])
        app.isAppStore = FileManager.default.fileExists(atPath: contents.appendingPathComponent("_MASReceipt/receipt").path)
        app.electronConfig = try? String(contentsOf: contents.appendingPathComponent("Resources/app-update.yml"), encoding: .utf8)
        return app
    }

    private static func text(_ value: Any?) -> String? {
        let string = (value as? String) ?? (value as? NSNumber)?.stringValue
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum AppScanner {
    static func isSpotlightCandidate(_ path: String, home: String) -> Bool {
        guard path.hasSuffix(".app"), path.hasPrefix(home + "/") else { return false }
        let parts = path.dropFirst(home.count + 1).split(separator: "/")
        return parts.first != "Library" && !parts.dropLast().contains { $0.hasSuffix(".app") || $0.hasPrefix(".") }
    }

    static func unique(_ apps: [AppBundle], ownBundleID: String?) -> [AppBundle] {
        var seen = Set<String>()
        return apps.filter { app in
            app.bundleID != ownBundleID && (!app.bundleID.hasPrefix("com.apple.") || app.isAppStore) && seen.insert(app.bundleID.lowercased()).inserted
        }
    }
}

struct FeedRelease: Equatable, Sendable {
    let version: String
    let build: String
    var minimumSystemVersion: String?

    func runs(on systemVersion: String) -> Bool {
        minimumSystemVersion.map { !AppVersion.isNewer($0, than: systemVersion) } ?? true
    }
}

enum Appcast {
    static func releases(in data: Data) -> [FeedRelease] {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return [] }
        return collector.releases
    }

    static func latest(in data: Data, systemVersion: String) -> FeedRelease? {
        releases(in: data).filter { $0.runs(on: systemVersion) }.max { AppVersion.compare($0.build, $1.build) == .orderedAscending }
    }

    private final class Collector: NSObject, XMLParserDelegate {
        private static let fields: Set<String> = ["sparkle:version", "sparkle:shortVersionString", "sparkle:minimumSystemVersion", "sparkle:channel"]

        var releases: [FeedRelease] = []
        private var item: [String: String]?
        private var enclosure: [String: String]?
        private var isInDeltas = false
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            text = ""
            switch elementName {
            case "item":
                item = [:]
                enclosure = nil
            case "sparkle:deltas":
                isInDeltas = true
            case "enclosure" where item != nil && !isInDeltas && enclosure == nil && attributes["sparkle:deltaFrom"] == nil:
                enclosure = attributes
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            switch elementName {
            case "sparkle:deltas":
                isInDeltas = false
            case "item":
                if let release = release() { releases.append(release) }
                item = nil
            case _ where Self.fields.contains(elementName) && !isInDeltas:
                item?[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                break
            }
        }

        private func release() -> FeedRelease? {
            guard let item, item["sparkle:channel"]?.isEmpty ?? true else { return nil }
            let system = enclosure?["sparkle:os"]?.lowercased()
            guard system == nil || system == "macos" || system == "osx" else { return nil }
            guard let build = item["sparkle:version"] ?? enclosure?["sparkle:version"], !build.isEmpty else { return nil }
            let version = item["sparkle:shortVersionString"] ?? enclosure?["sparkle:shortVersionString"] ?? build
            return FeedRelease(version: version, build: build, minimumSystemVersion: item["sparkle:minimumSystemVersion"])
        }
    }
}

enum ElectronFeed {
    static let fileName = "latest-mac.yml"

    static func fields(_ yaml: String) -> [String: String] {
        yaml.split(whereSeparator: \.isNewline).reduce(into: [:]) { result, line in
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-", let colon = line.firstIndex(of: ":") else { return }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "'" || quote == "\"", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
    }

    static func feedURL(fromConfig yaml: String) -> URL? {
        let config = fields(yaml)
        switch config["provider"] {
        case "generic":
            guard let base = config["url"], !base.isEmpty else { return nil }
            return URL(string: base.hasSuffix("/") ? base + fileName : base + "/" + fileName)
        case "github":
            guard let owner = config["owner"], let repo = config["repo"], config["private"] != "true" else { return nil }
            return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/\(fileName)")
        default:
            return nil
        }
    }

    static func latest(_ yaml: String) -> FeedRelease? {
        let values = fields(yaml)
        guard let version = values["version"], !version.isEmpty else { return nil }
        return FeedRelease(version: version, build: version, minimumSystemVersion: values["minimumSystemVersion"])
    }
}

struct StoreListing: Equatable, Sendable {
    let version: String
    let page: URL?
    var minimumSystemVersion: String?
}

enum AppStoreLookup {
    static let batchSize = 20
    static let updatesPage = URL(string: "macappstore://showUpdatesPage")!

    static func batches(_ bundleIDs: [String]) -> [[String]] {
        stride(from: 0, to: bundleIDs.count, by: batchSize).map { Array(bundleIDs[$0..<min($0 + batchSize, bundleIDs.count)]) }
    }

    static func url(for bundleIDs: [String], country: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [URLQueryItem(name: "bundleId", value: bundleIDs.joined(separator: ",")),
                                  URLQueryItem(name: "country", value: country.lowercased()),
                                  URLQueryItem(name: "entity", value: "macSoftware")]
        return components?.url
    }

    static func listings(from data: Data) -> [String: StoreListing]? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return response.results.reduce(into: [:]) { listings, result in
            guard let bundleID = result.bundleId, let version = result.version else { return }
            listings[bundleID.lowercased()] = StoreListing(version: version, page: result.trackViewUrl.flatMap(storePage),
                                                           minimumSystemVersion: result.minimumOsVersion)
        }
    }

    static func storePage(_ link: String) -> URL? {
        guard var components = URLComponents(string: link), components.scheme?.lowercased() == "https" else { return nil }
        components.scheme = "macappstore"
        return components.url
    }

    private struct Response: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let bundleId: String?
        let version: String?
        let trackViewUrl: String?
        let minimumOsVersion: String?
    }
}

struct CaskIndex: Sendable {
    private var byApp: [String: [BrewPackage]] = [:]
    private var byBundleID: [String: [BrewPackage]] = [:]

    init(_ casks: [BrewPackage]) {
        for cask in casks where cask.kind == .cask {
            for app in Set(cask.apps.map { $0.lowercased() }) { byApp[app, default: []].append(cask) }
            for bundleID in Set(cask.bundleIDs.map { $0.lowercased() }) { byBundleID[bundleID, default: []].append(cask) }
        }
    }

    func match(_ app: AppBundle) -> BrewPackage? {
        let named = byApp[app.fileName.lowercased()] ?? []
        let identified = byBundleID[app.bundleID.lowercased()] ?? []
        let both = named.filter { candidate in identified.contains { $0.id == candidate.id } }
        let candidates = !both.isEmpty ? both : !named.isEmpty ? named : identified
        return candidates.min { Self.rank($0) < Self.rank($1) }
    }

    private static func rank(_ cask: BrewPackage) -> (Int, Int, String) {
        (cask.name.contains("@") ? 1 : 0, cask.name.count, cask.name)
    }
}

enum AppUpdateSource: String, Sendable {
    case homebrew, appStore, sparkle, electron, catalog

    var title: String {
        switch self {
        case .homebrew: "Homebrew"
        case .appStore: "App Store"
        case .sparkle: "Sparkle feed"
        case .electron: "Electron feed"
        case .catalog: "Online catalog"
        }
    }
}

enum AppUpdateAction: Hashable, Sendable {
    case brew(String)
    case store(URL)
    case openApp
    case homepage(URL)
}

struct AppUpdate: Identifiable, Hashable, Sendable {
    let app: AppBundle
    let installed: String
    let latest: String
    let source: AppUpdateSource
    let action: AppUpdateAction

    var id: String { app.path }
    var noticeKey: String { "\(app.bundleID)@\(latest)" }
}

struct AppCheckFailure: Identifiable, Hashable, Sendable {
    let name: String
    var bundleID: String?
    let reason: String

    var id: String { "\(name)|\(reason)" }
}

struct AppUpdateReport: Sendable {
    var updates: [AppUpdate] = []
    var failures: [AppCheckFailure] = []
    var checked = 0
}

enum UpdateRoute: Hashable, Sendable {
    case appStore
    case homebrew(String)
    case sparkle(URL)
    case electron(URL)
    case catalog

    var isHomebrew: Bool {
        if case .homebrew = self { return true }
        return false
    }

    var feed: URL? {
        switch self {
        case .sparkle(let url), .electron(let url): url
        default: nil
        }
    }
}

enum FeedPolicy {
    static let maxBytes = 2 * 1024 * 1024
    static let concurrency = 4
    static let budget: TimeInterval = 60

    static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
    }
}

struct RoutedApp: Sendable {
    let app: AppBundle
    let route: UpdateRoute
}

enum FeedOutcome: Equatable, Sendable {
    case data(Data)
    case failed(String)
}

struct UpdateEvidence: Sendable {
    var systemVersion: String
    var outdatedCasks: [String: BrewOutdated]?
    var store: [String: StoreListing] = [:]
    var storeFailures: Set<String> = []
    var feeds: [String: FeedOutcome] = [:]
    var catalog: CaskIndex?
}

struct UpdateFetchPlan: Sendable {
    let storeBatches: [[String]]
    let requests: [String: URL]

    init(_ routed: [RoutedApp], country: String) {
        let batches = AppStoreLookup.batches(routed.filter { $0.route == .appStore }.map(\.app.bundleID))
        let store = batches.enumerated().compactMap { number, batch in
            AppStoreLookup.url(for: batch, country: country).map { (Self.storeKey(number), $0) }
        }
        let feeds = routed.compactMap { item in item.route.feed.map { (item.app.path, $0) } }
        storeBatches = batches
        requests = Dictionary(store + feeds, uniquingKeysWith: { first, _ in first })
    }

    func evidence(from results: [String: FeedOutcome], systemVersion: String) -> UpdateEvidence {
        var evidence = UpdateEvidence(systemVersion: systemVersion)
        for (number, batch) in storeBatches.enumerated() {
            if case .data(let data)? = results[Self.storeKey(number)], let listings = AppStoreLookup.listings(from: data) {
                evidence.store.merge(listings) { first, _ in first }
            } else {
                evidence.storeFailures.formUnion(batch.map { $0.lowercased() })
            }
        }
        evidence.feeds = results
        return evidence
    }

    private static func storeKey(_ batch: Int) -> String {
        "store.\(batch)"
    }
}

enum AppUpdatePlanner {
    enum Outcome: Equatable {
        case update(AppUpdate)
        case current
        case failed(String)
    }

    static let timedOut = "Ran out of time"

    static func route(_ app: AppBundle, settings: AppUpdateSettings, installedCasks: CaskIndex?) -> UpdateRoute? {
        if app.isAppStore { return settings.checksAppStore ? .appStore : nil }
        if let cask = installedCasks?.match(app) { return .homebrew(cask.name) }
        if let feed = app.feed.flatMap(URL.init(string:)), FeedPolicy.isAllowed(feed) { return .sparkle(feed) }
        if let config = app.electronConfig, let feed = ElectronFeed.feedURL(fromConfig: config), FeedPolicy.isAllowed(feed) { return .electron(feed) }
        return settings.usesCatalog ? .catalog : nil
    }

    static func report(_ routed: [RoutedApp], evidence: UpdateEvidence) -> AppUpdateReport {
        var report = AppUpdateReport(checked: routed.count)
        for item in routed {
            switch evaluate(item.app, route: item.route, evidence: evidence) {
            case .update(let update): report.updates.append(update)
            case .failed(let reason): report.failures.append(AppCheckFailure(name: item.app.name, bundleID: item.app.bundleID, reason: reason))
            case .current: break
            }
        }
        if evidence.outdatedCasks == nil, routed.contains(where: \.route.isHomebrew) {
            report.failures.append(AppCheckFailure(name: "Homebrew", reason: "brew outdated did not answer"))
        }
        if evidence.catalog == nil, routed.contains(where: { $0.route == .catalog }) {
            report.failures.append(AppCheckFailure(name: "Online catalog", reason: "formulae.brew.sh could not be reached"))
        }
        report.updates.sort { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        report.failures.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return report
    }

    static func evaluate(_ app: AppBundle, route: UpdateRoute, evidence: UpdateEvidence) -> Outcome {
        switch route {
        case .appStore:
            let key = app.bundleID.lowercased()
            if evidence.storeFailures.contains(key) { return .failed("The App Store did not answer") }
            guard let listing = evidence.store[key] else { return .failed("Not found in the App Store for this region") }
            guard FeedRelease(version: listing.version, build: listing.version, minimumSystemVersion: listing.minimumSystemVersion)
                .runs(on: evidence.systemVersion) else { return .current }
            return offer(app, installed: app.version, latest: listing.version, source: .appStore,
                         action: .store(listing.page ?? AppStoreLookup.updatesPage))
        case .homebrew(let token):
            guard let entry = evidence.outdatedCasks?[token], !entry.isPinned else { return .current }
            let latest = AppVersion.caskVersion(entry.currentVersion)
            return offer(app, installed: AppVersion.installed(app.version, build: app.build, matching: latest), latest: latest, source: .homebrew,
                         action: .brew(token))
        case .sparkle:
            return evaluateFeed(app, isSparkle: true, evidence: evidence)
        case .electron:
            return evaluateFeed(app, isSparkle: false, evidence: evidence)
        case .catalog:
            guard let cask = evidence.catalog?.match(app), let homepage = cask.homepage else { return .current }
            let latest = AppVersion.caskVersion(cask.latestVersion)
            return offer(app, installed: AppVersion.installed(app.version, build: app.build, matching: latest), latest: latest, source: .catalog,
                         action: .homepage(homepage))
        }
    }

    private static func evaluateFeed(_ app: AppBundle, isSparkle: Bool, evidence: UpdateEvidence) -> Outcome {
        let data: Data
        switch evidence.feeds[app.path] {
        case .data(let body)?: data = body
        case .failed(let reason)?: return .failed(reason)
        case nil: return .failed(timedOut)
        }
        let release = isSparkle ? Appcast.latest(in: data, systemVersion: evidence.systemVersion) : ElectronFeed.latest(String(decoding: data, as: UTF8.self))
        guard let release else { return .failed("The update feed lists no release for this Mac") }
        guard release.runs(on: evidence.systemVersion) else { return .current }
        let isNewer = isSparkle ? AppVersion.isNewer(release.build, than: app.build) : AppVersion.isNewer(release.version, than: app.version)
        guard isNewer else { return .current }
        return .update(AppUpdate(app: app, installed: AppVersion.label(app.version, build: app.build, against: release.version),
                                 latest: AppVersion.label(release.version, build: release.build, against: app.version),
                                 source: isSparkle ? .sparkle : .electron, action: .openApp))
    }

    private static func offer(_ app: AppBundle, installed: String, latest: String, source: AppUpdateSource, action: AppUpdateAction) -> Outcome {
        guard !latest.isEmpty, latest != "latest", AppVersion.isNewer(latest, than: installed) else { return .current }
        return .update(AppUpdate(app: app, installed: installed, latest: latest, source: source, action: action))
    }
}

struct AppUpdatePlan: Equatable {
    var brewTokens: [String] = []
    var storePages: [URL] = []
    var appPaths: [String] = []
    var homepages: [URL] = []

    init(_ updates: [AppUpdate]) {
        for update in updates {
            switch update.action {
            case .brew(let token): brewTokens.append(token)
            case .store(let page): storePages.append(page)
            case .openApp: appPaths.append(update.app.path)
            case .homepage(let page): homepages.append(page)
            }
        }
    }

    var storeLinks: [URL] { storePages.count > 1 ? [AppStoreLookup.updatesPage] : storePages }

    var summary: String {
        var lines: [String] = []
        if !brewTokens.isEmpty { lines.append("Homebrew runs: brew upgrade --cask --greedy \(brewTokens.joined(separator: " "))") }
        if !storePages.isEmpty { lines.append(storePages.count == 1 ? "Opens the app's App Store page." : "Opens the App Store updates page.") }
        if !appPaths.isEmpty { lines.append(appPaths.count == 1 ? "Opens 1 app so it can update itself." : "Opens \(appPaths.count) apps so they can update themselves.") }
        if !homepages.isEmpty { lines.append(homepages.count == 1 ? "Opens 1 download page." : "Opens \(homepages.count) download pages.") }
        return lines.joined(separator: "\n")
    }
}

enum AppUpdateSchedule: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, daily, weekly

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 86_400
        case .weekly: 604_800
        }
    }

    func nextCheck(after lastCheck: Date?, notBefore earliest: Date) -> Date? {
        guard let interval else { return nil }
        return max(lastCheck.map { $0.addingTimeInterval(interval) } ?? earliest, earliest)
    }
}

struct AppUpdateRules: Codable, Equatable, Sendable {
    var excludedBundleIDs: [String] = []
    var skippedVersions: [String: String] = [:]

    func isExcluded(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    func allows(_ update: AppUpdate) -> Bool {
        !isExcluded(update.app.bundleID) && skippedVersions[update.app.bundleID] != update.latest
    }
}

struct AppUpdateSettings: Codable, Equatable, Sendable {
    var schedule = AppUpdateSchedule.off
    var notifies = false
    var checksHomebrew = false
    var checksAppStore = false
    var usesCatalog = false
    var rules = AppUpdateRules()
    var lastCheck: Date?
    var notifiedKeys: [String] = []
}

enum UpdateNotice {
    static let memory = 500
    static let namesShown = 3

    static func fresh(_ updates: [AppUpdate], notified: [String]) -> [AppUpdate] {
        let known = Set(notified)
        return updates.filter { !known.contains($0.noticeKey) }
    }

    static func remembering(_ updates: [AppUpdate], in notified: [String]) -> [String] {
        Array((notified + updates.map(\.noticeKey)).suffix(memory))
    }

    static func body(_ updates: [AppUpdate]) -> String {
        let names = updates.prefix(namesShown).map { "\($0.app.name) \($0.latest)" }.joined(separator: ", ")
        return updates.count > namesShown ? "\(names) and \(updates.count - namesShown) more" : names
    }
}
