import Foundation

enum AIAgent: Int, CaseIterable, Identifiable {
    case claude = 0
    case codex = 1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0

    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
    var total: Int { input + output + cacheRead + cacheWrite }

    static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead,
                    cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m, cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h)
    }
}

struct AIUsageRow: Equatable {
    var date: Date
    var agent: AIAgent
    var model: String
    var project = ""
    var session = ""
    var tier = ""
    var tokens = TokenCounts()
    var webSearches = 0
    var requests = 1
}

struct ModelPrice: Equatable {
    let family: String
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
    let webSearch: Double
}

enum AIPricing {
    static let asOf = "November 10, 2026"
    static let tokensPerPrice = 1_000_000.0
    static let claudeWebSearch = 10.0 / 1000
    static let pricedTiers: Set<String> = ["", "standard"]
    static let snapshotSeparators: Set<Character> = ["-", "@", ":", "_"]
    static let snapshotDigits = 4

    static let table: [ModelPrice] = [
        claude("claude-fable-5-2", input: 8, write5m: 10, write1h: 16, cacheRead: 0.20, output: 40),
        claude("claude-mythos-5-2", input: 8, write5m: 10, write1h: 16, cacheRead: 0.20, output: 40),
        claude("claude-fable-5-1", input: 10, write5m: 12.50, write1h: 20, cacheRead: 0.25, output: 50),
        claude("claude-mythos-5-1", input: 10, write5m: 12.50, write1h: 20, cacheRead: 0.25, output: 50),
        claude("claude-fable-5", input: 10, write5m: 12.50, write1h: 20, cacheRead: 1, output: 50),
        claude("claude-mythos-5", input: 10, write5m: 12.50, write1h: 20, cacheRead: 1, output: 50),
        claude("claude-opus-5-5", input: 4, write5m: 5, write1h: 8, cacheRead: 0.20, output: 20),
        claude("claude-opus-5", input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.50, output: 25),
        claude("claude-opus-4-8", input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.50, output: 25),
        claude("claude-opus-4-7", input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.50, output: 25),
        claude("claude-opus-4-6", input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.50, output: 25),
        claude("claude-opus-4-5", input: 5, write5m: 6.25, write1h: 10, cacheRead: 0.50, output: 25),
        claude("claude-opus-4-1", input: 15, write5m: 18.75, write1h: 30, cacheRead: 1.50, output: 75),
        claude("claude-opus-4", input: 15, write5m: 18.75, write1h: 30, cacheRead: 1.50, output: 75),
        claude("claude-opus-4-0", input: 15, write5m: 18.75, write1h: 30, cacheRead: 1.50, output: 75),
        claude("claude-sonnet-5-5", input: 2, write5m: 2.50, write1h: 4, cacheRead: 0.10, output: 10),
        claude("claude-sonnet-5", input: 2, write5m: 2.50, write1h: 4, cacheRead: 0.20, output: 10),
        claude("claude-sonnet-4-6", input: 3, write5m: 3.75, write1h: 6, cacheRead: 0.30, output: 15),
        claude("claude-sonnet-4-5", input: 3, write5m: 3.75, write1h: 6, cacheRead: 0.30, output: 15),
        claude("claude-sonnet-4", input: 3, write5m: 3.75, write1h: 6, cacheRead: 0.30, output: 15),
        claude("claude-sonnet-4-0", input: 3, write5m: 3.75, write1h: 6, cacheRead: 0.30, output: 15),
        claude("claude-haiku-4-5", input: 1, write5m: 1.25, write1h: 2, cacheRead: 0.10, output: 5),
        openAI("gpt-5", input: 1.25, cachedInput: 0.125, output: 10),
        openAI("gpt-5-codex", input: 1.25, cachedInput: 0.125, output: 10),
        openAI("gpt-5-mini", input: 0.25, cachedInput: 0.025, output: 2),
        openAI("gpt-5-nano", input: 0.05, cachedInput: 0.005, output: 0.40),
        openAI("gpt-5.1", input: 1.25, cachedInput: 0.125, output: 10),
        openAI("gpt-5.1-codex", input: 1.25, cachedInput: 0.125, output: 10),
        openAI("gpt-5.1-codex-max", input: 1.25, cachedInput: 0.125, output: 10),
        openAI("gpt-5.1-codex-mini", input: 0.25, cachedInput: 0.025, output: 2),
        openAI("gpt-5.2", input: 1.75, cachedInput: 0.175, output: 14),
        openAI("gpt-5.2-codex", input: 1.75, cachedInput: 0.175, output: 14),
        openAI("gpt-5.3-codex", input: 1.75, cachedInput: 0.175, output: 14),
        openAI("gpt-5.4-mini", input: 0.75, cachedInput: 0.075, output: 4.50),
        openAI("gpt-5.4-nano", input: 0.20, cachedInput: 0.02, output: 1.25),
    ]

    private static func claude(_ family: String, input: Double, write5m: Double, write1h: Double, cacheRead: Double, output: Double) -> ModelPrice {
        ModelPrice(family: family, input: input, output: output, cacheRead: cacheRead, cacheWrite5m: write5m, cacheWrite1h: write1h,
                   webSearch: claudeWebSearch)
    }

    private static func openAI(_ family: String, input: Double, cachedInput: Double, output: Double) -> ModelPrice {
        ModelPrice(family: family, input: input, output: output, cacheRead: cachedInput, cacheWrite5m: input, cacheWrite1h: input, webSearch: 0)
    }

    static func normalize(_ model: String) -> String {
        var name = model.lowercased().trimmingCharacters(in: .whitespaces)
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if let vendor = name.range(of: "anthropic.", options: .backwards) { name = String(name[vendor.upperBound...]) }
        return name
    }

    static func matches(_ name: String, family: String) -> Bool {
        guard name.hasPrefix(family) else { return false }
        let rest = name.dropFirst(family.count)
        guard let separator = rest.first else { return true }
        return snapshotSeparators.contains(separator) && rest.dropFirst().prefix(while: \.isASCIIDigit).count >= snapshotDigits
    }

    static func price(for model: String, in table: [ModelPrice] = table) -> ModelPrice? {
        let name = normalize(model)
        return table.filter { matches(name, family: $0.family) }.max { $0.family.count < $1.family.count }
    }

    static func prices(for models: some Sequence<String>, in table: [ModelPrice] = table) -> [String: ModelPrice] {
        var prices: [String: ModelPrice] = [:]
        for model in models where prices[model] == nil {
            prices[model] = price(for: model, in: table)
        }
        return prices
    }

    static func price(for row: AIUsageRow, in prices: [String: ModelPrice]) -> ModelPrice? {
        pricedTiers.contains(row.tier) ? prices[row.model] : nil
    }

    static func cost(_ row: AIUsageRow, at price: ModelPrice) -> Double {
        let tokens = row.tokens
        let perMillion = Double(tokens.input) * price.input + Double(tokens.output) * price.output + Double(tokens.cacheRead) * price.cacheRead
            + Double(tokens.cacheWrite5m) * price.cacheWrite5m + Double(tokens.cacheWrite1h) * price.cacheWrite1h
        return perMillion / tokensPerPrice + Double(row.webSearches) * price.webSearch
    }

    static func savings(_ row: AIUsageRow, at price: ModelPrice) -> Double {
        Double(row.tokens.cacheRead) * (price.input - price.cacheRead) / tokensPerPrice
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

enum UsageWindow: String, CaseIterable, Identifiable {
    case today, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        }
    }

    var barUnit: Calendar.Component { self == .today ? .hour : .day }

    func start(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1 - days, to: today) ?? today
    }
}

struct AIUsageBar: Identifiable, Equatable {
    let start: Date
    var tokens = 0
    var cost = 0.0

    var id: Date { start }
}

struct UsageSlice: Identifiable, Equatable {
    let name: String
    var tokens = TokenCounts()
    var cost = 0.0
    var unpricedTokens = 0
    var requests = 0

    var id: String { name }
    var isPriced: Bool { unpricedTokens < tokens.total || tokens.total == 0 }
    var isPartlyPriced: Bool { unpricedTokens > 0 && isPriced }

    mutating func add(_ row: AIUsageRow, cost: Double?) {
        tokens = tokens + row.tokens
        self.cost += cost ?? 0
        unpricedTokens += cost == nil ? row.tokens.total : 0
        requests += row.requests
    }
}

struct UsageSummary: Equatable {
    var total = UsageSlice(name: "")
    var savings = 0.0
    var sessions = 0
    var unpricedModels: [String] = []
    var byAgent: [UsageSlice] = []
    var byModel: [UsageSlice] = []
    var byProject: [UsageSlice] = []
    var bars: [AIUsageBar] = []
}

struct BurnRate: Equatable {
    var tokensPerHour = 0
    var costPerHour = 0.0
}

struct UsageBlock: Equatable {
    static let length: TimeInterval = 5 * 3600

    let start: Date
    var usage = UsageSlice(name: "")

    var end: Date { start.addingTimeInterval(Self.length) }
}

enum UsageMath {
    static let burnWindow: TimeInterval = 30 * 60
    static let secondsPerHour: TimeInterval = 3600

    static func summary(of rows: [AIUsageRow], window: UsageWindow, now: Date, calendar: Calendar, prices: [String: ModelPrice]) -> UsageSummary {
        let start = window.start(now: now, calendar: calendar)
        var summary = UsageSummary(bars: bars(from: start, window: window, now: now, calendar: calendar))
        var agents: [String: UsageSlice] = [:]
        var models: [String: UsageSlice] = [:]
        var projects: [String: UsageSlice] = [:]
        var sessions = Set<String>()
        var unpriced = Set<String>()
        for row in rows where row.date >= start && row.date <= now {
            let price = AIPricing.price(for: row, in: prices)
            let cost = price.map { AIPricing.cost(row, at: $0) }
            summary.total.add(row, cost: cost)
            summary.savings += price.map { AIPricing.savings(row, at: $0) } ?? 0
            agents[row.agent.title, default: UsageSlice(name: row.agent.title)].add(row, cost: cost)
            models[row.model, default: UsageSlice(name: row.model)].add(row, cost: cost)
            projects[row.project, default: UsageSlice(name: row.project)].add(row, cost: cost)
            if !row.session.isEmpty { sessions.insert("\(row.agent.rawValue) \(row.session)") }
            if cost == nil { unpriced.insert(row.model) }
            if let index = barIndex(of: row.date, from: start, window: window, calendar: calendar), summary.bars.indices.contains(index) {
                summary.bars[index].tokens += row.tokens.total
                summary.bars[index].cost += cost ?? 0
            }
        }
        summary.sessions = sessions.count
        summary.unpricedModels = unpriced.sorted()
        summary.byAgent = ranked(agents)
        summary.byModel = ranked(models)
        summary.byProject = ranked(projects)
        return summary
    }

    static func bars(from start: Date, window: UsageWindow, now: Date, calendar: Calendar) -> [AIUsageBar] {
        let count: Int
        if window == .today {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24 * secondsPerHour)
            count = Int((tomorrow.timeIntervalSince(start) / secondsPerHour).rounded())
        } else {
            count = window.days
        }
        return (0..<count).compactMap { calendar.date(byAdding: window.barUnit, value: $0, to: start) }.map { AIUsageBar(start: $0) }
    }

    static func barIndex(of date: Date, from start: Date, window: UsageWindow, calendar: Calendar) -> Int? {
        if window == .today { return Int(date.timeIntervalSince(start) / secondsPerHour) }
        return calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day
    }

    static func ranked(_ slices: [String: UsageSlice]) -> [UsageSlice] {
        slices.values.sorted { ($0.cost, $0.tokens.total, $1.name) > ($1.cost, $1.tokens.total, $0.name) }
    }

    static func burnRate(of rows: [AIUsageRow], now: Date, prices: [String: ModelPrice]) -> BurnRate {
        let since = now.addingTimeInterval(-burnWindow)
        var recent = UsageSlice(name: "")
        for row in rows where row.date > since && row.date <= now {
            recent.add(row, cost: AIPricing.price(for: row, in: prices).map { AIPricing.cost(row, at: $0) })
        }
        let factor = secondsPerHour / burnWindow
        return BurnRate(tokensPerHour: Int(Double(recent.tokens.total) * factor), costPerHour: recent.cost * factor)
    }

    static func blocks(of rows: [AIUsageRow], prices: [String: ModelPrice]) -> [UsageBlock] {
        var blocks: [UsageBlock] = []
        for row in rows.filter({ $0.agent == .claude }).sorted(by: { $0.date < $1.date }) {
            if blocks.last.map({ row.date >= $0.end }) ?? true { blocks.append(UsageBlock(start: row.date)) }
            blocks[blocks.count - 1].usage.add(row, cost: AIPricing.price(for: row, in: prices).map { AIPricing.cost(row, at: $0) })
        }
        return blocks
    }

    static func activeBlock(of rows: [AIUsageRow], now: Date, prices: [String: ModelPrice]) -> UsageBlock? {
        blocks(of: rows.filter { $0.date <= now }, prices: prices).last.flatMap { now < $0.end ? $0 : nil }
    }
}

struct CodexLimitWindow: Decodable, Equatable {
    static let minutesPerHour = 60
    static let minutesPerDay = 1440
    static let minutesPerWeek = 10080

    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Int64?

    var resetDate: Date? { resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    var title: String {
        guard let minutes = windowMinutes, minutes > 0 else { return "Usage" }
        if minutes == Self.minutesPerWeek { return "Weekly" }
        if minutes % Self.minutesPerDay == 0 { return "\(minutes / Self.minutesPerDay)-day" }
        if minutes % Self.minutesPerHour == 0 { return "\(minutes / Self.minutesPerHour)-hour" }
        return "\(minutes)-minute"
    }

    func percent(at now: Date) -> Double {
        if let reset = resetDate, reset <= now { return 0 }
        return min(max(usedPercent, 0), 100)
    }
}

struct CodexLimits: Decodable, Equatable {
    let observedAt: Int64
    let primary: CodexLimitWindow?
    let secondary: CodexLimitWindow?

    var windows: [CodexLimitWindow] { [primary, secondary].compactMap { $0 } }
}

struct AIUsageSnapshot: Equatable {
    static let rowWidth = 13

    var generation: UInt64
    var rows: [AIUsageRow]?
    var limits: CodexLimits?
    var files = 0
    var error: String?

    private struct Payload: Decodable {
        let generation: UInt64
        let names: [String]?
        let rows: [Int64]?
        let limits: CodexLimits?
        let files: Int?
        let error: String?
    }

    init(generation: UInt64, rows: [AIUsageRow]? = nil, limits: CodexLimits? = nil, files: Int = 0, error: String? = nil) {
        self.generation = generation
        self.rows = rows
        self.limits = limits
        self.files = files
        self.error = error
    }

    init(json: Data) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: json)
        self.init(generation: payload.generation, rows: payload.rows.map { Self.rows($0, names: payload.names ?? []) }, limits: payload.limits,
                  files: payload.files ?? 0, error: payload.error.flatMap { $0.isEmpty ? nil : $0 })
    }

    static func rows(_ flat: [Int64], names: [String]) -> [AIUsageRow] {
        func name(_ index: Int64) -> String { names.indices.contains(Int(index)) ? names[Int(index)] : "" }
        return stride(from: 0, to: flat.count - flat.count % rowWidth, by: rowWidth).compactMap { start in
            let value = { (offset: Int) in Int(flat[start + offset]) }
            guard let agent = AIAgent(rawValue: value(1)) else { return nil }
            return AIUsageRow(date: Date(timeIntervalSince1970: TimeInterval(flat[start])), agent: agent, model: name(flat[start + 2]),
                              project: name(flat[start + 3]), session: name(flat[start + 4]), tier: name(flat[start + 5]),
                              tokens: TokenCounts(input: value(6), output: value(7), cacheRead: value(8), cacheWrite5m: value(9), cacheWrite1h: value(10)),
                              webSearches: value(11), requests: value(12))
        }
    }
}

struct AIUsagePaths {
    static let rowDays = 31
    static let secondsPerDay: Int64 = 86400

    var cache: URL
    var claude: [URL]
    var codex: [URL]

    static var standard: AIUsagePaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CleanMacOS", isDirectory: true)
        return AIUsagePaths(cache: support.appendingPathComponent("ai-usage.cache"),
                            claude: [".claude/projects", ".config/claude/projects"].map { home.appendingPathComponent($0, isDirectory: true) },
                            codex: [".codex/sessions", ".codex/archived_sessions"].map { home.appendingPathComponent($0, isDirectory: true) })
    }

    private struct Request: Encodable {
        let cache: String
        let claude: [String]
        let codex: [String]
        let now: Int64
        let since: Int64
        let known: UInt64
        let release: Bool
    }

    func request(now: Date, known: UInt64, release: Bool = false) -> Data {
        let seconds = Int64(now.timeIntervalSince1970)
        let request = Request(cache: cache.path, claude: claude.map(\.path), codex: codex.map(\.path), now: seconds,
                              since: seconds - Int64(Self.rowDays) * Self.secondsPerDay, known: known, release: release)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(request)) ?? Data()
    }
}

struct AIUsageSettings: Codable, Equatable {
    var isEnabled = false
}

@MainActor
final class AIUsageMonitor: ObservableObject {
    static let settingsKey = "aiUsage.settings"
    static let pollInterval: TimeInterval = 30

    @Published var settings: AIUsageSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey)
            if oldValue.isEnabled != settings.isEnabled { apply() }
        }
    }
    @Published private(set) var rows: [AIUsageRow] = []
    @Published private(set) var prices: [String: ModelPrice] = [:]
    @Published private(set) var limits: CodexLimits?
    @Published private(set) var files = 0
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isReading = false
    @Published private(set) var message: String?

    private let paths: AIUsagePaths
    private let queue = DispatchQueue(label: "mackit.ai-usage", qos: .utility)
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var run = 0

    init(paths: AIUsagePaths = .standard) {
        self.paths = paths
        settings = UserDefaults.standard.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(AIUsageSettings.self, from: $0) }
            ?? AIUsageSettings()
        apply()
    }

    func refresh() {
        guard settings.isEnabled, !isReading else { return }
        isReading = true
        let request = paths.request(now: Date(), known: generation)
        let current = run
        queue.async {
            let reply = RustCore.aiUsage(request)
            let snapshot = try? AIUsageSnapshot(json: reply)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.receive(snapshot, run: current) }
            }
        }
    }

    private func receive(_ snapshot: AIUsageSnapshot?, run current: Int) {
        guard current == run, settings.isEnabled else { return }
        isReading = false
        guard let snapshot else {
            message = "Could not read the usage logs."
            return
        }
        generation = snapshot.generation
        if let fresh = snapshot.rows {
            rows = fresh
            prices = AIPricing.prices(for: fresh.map(\.model))
        }
        limits = snapshot.limits
        files = snapshot.files
        message = snapshot.error
        updatedAt = Date()
    }

    private func apply() {
        if settings.isEnabled { start() } else { stop() }
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func stop() {
        guard let timer else { return }
        timer.invalidate()
        self.timer = nil
        run += 1
        generation = 0
        rows = []
        prices = [:]
        limits = nil
        files = 0
        updatedAt = nil
        isReading = false
        message = nil
        let request = paths.request(now: Date(), known: 0, release: true)
        queue.async { _ = RustCore.aiUsage(request) }
    }
}
