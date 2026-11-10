import Foundation
import Testing
@testable import CleanMacOS

struct AIUsageTests {
    private static let now = Date(timeIntervalSince1970: 1_794_312_000)
    private static let midnight = Date(timeIntervalSince1970: 1_794_268_800)
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86400
    private static let utc = calendar("UTC")
    private static let testPrice = ModelPrice(family: "test-model", input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6, webSearch: 0.01)

    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .gmt
        return calendar
    }

    private func row(_ secondsAgo: TimeInterval, agent: AIAgent = .claude, model: String = "claude-opus-5-5", project: String = "mackit",
                     session: String = "s1", tier: String = "standard") -> AIUsageRow {
        AIUsageRow(date: Self.now.addingTimeInterval(-secondsAgo), agent: agent, model: model, project: project, session: session, tier: tier,
                   tokens: TokenCounts(input: 1_000_000))
    }

    private func close(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 1e-9
    }

    private func write(_ lines: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try Data((text + "\n").utf8).write(to: url)
    }

    @Test func normalizesCaseProviderPrefixesAndContextSuffixes() {
        #expect(AIPricing.normalize(" Claude-Sonnet-4-5[1m] ") == "claude-sonnet-4-5")
        #expect(AIPricing.normalize("us.anthropic.claude-opus-4-1-20250805-v1:0") == "claude-opus-4-1-20250805-v1:0")
        #expect(AIPricing.normalize("openai/gpt-5.1-codex") == "gpt-5.1-codex")
    }

    @Test func takesTheLongestFamilyAndAllowsOnlyADatedSnapshotAfterIt() {
        let table = ["gpt-5", "gpt-5.1", "claude-opus-4", "claude-opus-4-1"].map {
            ModelPrice(family: $0, input: 1, output: 1, cacheRead: 1, cacheWrite5m: 1, cacheWrite1h: 1, webSearch: 0)
        }
        let family = { (model: String) in AIPricing.price(for: model, in: table)?.family }
        #expect(family("claude-opus-4-1-20250805") == "claude-opus-4-1")
        #expect(family("claude-opus-4-20250514") == "claude-opus-4")
        #expect(family("us.anthropic.claude-opus-4-1-20250805-v1:0") == "claude-opus-4-1")
        #expect(family("claude-opus-4-1@20250805") == "claude-opus-4-1")
        #expect(family("gpt-5-2025-08-07") == "gpt-5")
        #expect(family("gpt-5.1") == "gpt-5.1")
        for unknown in ["claude-opus-4-7", "gpt-5-mini", "gpt-5.1-codex", "gpt-50", "llama-3", ""] {
            #expect(family(unknown) == nil, "\(unknown)")
        }
    }

    @Test func theShippedTablePricesKnownModelsAndLeavesTheRestUnpriced() {
        #expect(AIPricing.price(for: "claude-opus-5-5")?.input == 4)
        #expect(AIPricing.price(for: "claude-sonnet-5-5")?.cacheRead == 0.10)
        #expect(AIPricing.price(for: "claude-opus-5")?.output == 25)
        #expect(AIPricing.price(for: "claude-sonnet-4-5-20250929")?.family == "claude-sonnet-4-5")
        #expect(AIPricing.price(for: "claude-opus-4-20250514")?.family == "claude-opus-4")
        #expect(AIPricing.price(for: "gpt-5.1-codex-max")?.output == 10)
        #expect(AIPricing.price(for: "gpt-5.2-codex")?.cacheRead == 0.175)
        for unpriced in ["claude-haiku-5-5", "gpt-6-astra", "gpt-6-luna", "gpt-5.5", "gpt-5.4", "claude-3-5-sonnet-20241022", "<synthetic>"] {
            #expect(AIPricing.price(for: unpriced) == nil, "\(unpriced)")
        }
        #expect(Set(AIPricing.table.map(\.family)).count == AIPricing.table.count)
        #expect(AIPricing.table.allSatisfy { $0.cacheRead < $0.input && $0.input < $0.output })
    }

    @Test func costsEveryTokenKindAndWebSearchesAtListPrices() {
        var usage = row(0)
        usage.tokens = TokenCounts(input: 1_000_000, output: 2_000_000, cacheRead: 10_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 500_000)
        usage.webSearches = 3
        #expect(close(AIPricing.cost(usage, at: Self.testPrice), 3 + 30 + 3 + 3.75 + 3 + 0.03))
        #expect(close(AIPricing.savings(usage, at: Self.testPrice), 27))
    }

    @Test func otherTiersAndUnknownModelsStayUnpriced() {
        let prices = AIPricing.prices(for: ["claude-opus-5-5", "mystery", "gpt-5.2"])
        #expect(prices["mystery"] == nil)
        #expect(AIPricing.price(for: row(0), in: prices) != nil)
        #expect(AIPricing.price(for: row(0, agent: .codex, model: "gpt-5.2", tier: ""), in: prices) != nil)
        for tier in ["standard/us", "standard/fast", "priority", "batch"] {
            #expect(AIPricing.price(for: row(0, tier: tier), in: prices) == nil, "\(tier)")
        }
        let summary = UsageMath.summary(of: [row(60), row(120, model: "mystery")], window: .today, now: Self.now, calendar: Self.utc, prices: prices)
        #expect(summary.unpricedModels == ["mystery"])
        #expect(summary.total.unpricedTokens == 1_000_000)
        #expect(close(summary.total.cost, 4))
        #expect(summary.byModel.first { $0.name == "mystery" }?.isPriced == false)
        #expect(summary.byAgent.first?.isPartlyPriced == true)
    }

    @Test func windowsStartAtLocalMidnight() {
        #expect(UsageWindow.today.start(now: Self.now, calendar: Self.utc) == Self.midnight)
        #expect(UsageWindow.week.start(now: Self.now, calendar: Self.utc) == Self.midnight.addingTimeInterval(-6 * Self.day))
        #expect(UsageWindow.month.start(now: Self.now, calendar: Self.utc) == Self.midnight.addingTimeInterval(-29 * Self.day))
        #expect(UsageWindow.today.start(now: Self.now, calendar: Self.calendar("Asia/Ho_Chi_Minh")) == Self.midnight.addingTimeInterval(-7 * Self.hour))
        let rows = [row(Self.hour), row(13 * Self.hour), row(8 * Self.day), row(40 * Self.day), row(-60)]
        let requests = UsageWindow.allCases.map { UsageMath.summary(of: rows, window: $0, now: Self.now, calendar: Self.utc, prices: [:]).total.requests }
        #expect(requests == [1, 2, 3])
    }

    @Test func todayHasHourlyBarsAndLongerWindowsHaveDailyBars() {
        let prices = AIPricing.prices(for: ["claude-opus-5-5"])
        let today = UsageMath.summary(of: [row(30 * 60), row(90 * 60)], window: .today, now: Self.now, calendar: Self.utc, prices: prices)
        #expect(today.bars.count == 24)
        #expect(close(today.bars[11].cost, 4) && close(today.bars[10].cost, 4) && today.bars[12].tokens == 0)
        let month = UsageMath.summary(of: [row(8 * Self.day)], window: .month, now: Self.now, calendar: Self.utc, prices: prices)
        #expect(month.bars.count == 30)
        #expect(month.bars[21].tokens == 1_000_000)
        #expect(month.bars.last?.start == Self.midnight)
        let newYork = Self.calendar("America/New_York")
        let fallBack = Date(timeIntervalSince1970: 1_793_574_000)
        let start = UsageWindow.today.start(now: fallBack, calendar: newYork)
        #expect(UsageMath.bars(from: start, window: .today, now: fallBack, calendar: newYork).count == 25)
    }

    @Test func breaksDownByAgentModelAndProjectByCost() {
        let prices = AIPricing.prices(for: ["claude-opus-5-5", "gpt-5.2"])
        let rows = [row(60), row(120, project: "api"), row(180, agent: .codex, model: "gpt-5.2", project: "api", session: "c1", tier: "")]
        let summary = UsageMath.summary(of: rows, window: .today, now: Self.now, calendar: Self.utc, prices: prices)
        #expect(summary.byAgent.map(\.name) == ["Claude Code", "Codex"])
        #expect(summary.byModel.map(\.name) == ["claude-opus-5-5", "gpt-5.2"])
        #expect(summary.byProject.map(\.name) == ["api", "mackit"])
        #expect(close(summary.byProject[0].cost, 5.75))
        #expect(summary.sessions == 2)
        #expect(summary.total.requests == 3)
    }

    @Test func burnRateDoublesTheLastThirtyMinutes() {
        let prices = AIPricing.prices(for: ["claude-opus-5-5"])
        let rate = UsageMath.burnRate(of: [row(10 * 60), row(29 * 60), row(40 * 60), row(-60)], now: Self.now, prices: prices)
        #expect(rate.tokensPerHour == 4_000_000)
        #expect(close(rate.costPerHour, 16))
    }

    @Test func blocksStartAtTheFirstRequestAfterThePreviousBlockEnded() {
        let first = 12 * Self.hour
        let rows = [row(first - Self.hour), row(first), row(first - 4 * Self.hour - 59 * 60), row(first - 5 * Self.hour),
                    row(first - 5.5 * Self.hour, agent: .codex, model: "gpt-5.2"), row(Self.hour)]
        let blocks = UsageMath.blocks(of: rows, prices: [:])
        #expect(blocks.map(\.start) == [Self.now.addingTimeInterval(-first), Self.now.addingTimeInterval(-first + 5 * Self.hour), Self.now.addingTimeInterval(-Self.hour)])
        #expect(blocks.map(\.usage.requests) == [3, 1, 1])
        #expect(UsageMath.activeBlock(of: rows, now: Self.now, prices: [:])?.end == Self.now.addingTimeInterval(4 * Self.hour))
        #expect(UsageMath.activeBlock(of: rows, now: Self.now.addingTimeInterval(4 * Self.hour), prices: [:]) == nil)
    }

    @Test func codexLimitWindowsAreNamedAndDropToZeroAfterTheirReset() {
        let reset = Int64(Self.now.timeIntervalSince1970) + 600
        let fiveHour = CodexLimitWindow(usedPercent: 42.5, windowMinutes: 300, resetsAt: reset)
        #expect(fiveHour.title == "5-hour")
        #expect(fiveHour.percent(at: Self.now) == 42.5)
        #expect(fiveHour.percent(at: Self.now.addingTimeInterval(601)) == 0)
        #expect(CodexLimitWindow(usedPercent: 140, windowMinutes: 10080, resetsAt: nil).percent(at: Self.now) == 100)
        let titles = [10080, 2880, 45, 0].map { CodexLimitWindow(usedPercent: 1, windowMinutes: $0, resetsAt: nil).title }
        #expect(titles == ["Weekly", "2-day", "45-minute", "Usage"])
    }

    @Test func decodesRowsNamesAndLimitsFromTheRustReply() throws {
        let json = """
        {"generation":7,"names":["claude-opus-5-5","mackit","s1","standard"],
         "rows":[1794312000,0,0,1,2,3,10,20,30,40,50,2,3,1794312060,1,9,1,2,3,1,1,1,0,0,0,1,1794312120],
         "limits":{"observedAt":1794312000,"primary":{"usedPercent":12.5,"windowMinutes":300,"resetsAt":1794315600}},"files":4}
        """
        let snapshot = try AIUsageSnapshot(json: Data(json.utf8))
        #expect(snapshot.generation == 7 && snapshot.files == 4 && snapshot.error == nil)
        #expect(snapshot.rows == [
            AIUsageRow(date: Self.now, agent: .claude, model: "claude-opus-5-5", project: "mackit", session: "s1", tier: "standard",
                       tokens: TokenCounts(input: 10, output: 20, cacheRead: 30, cacheWrite5m: 40, cacheWrite1h: 50), webSearches: 2, requests: 3),
            AIUsageRow(date: Self.now.addingTimeInterval(60), agent: .codex, model: "", project: "mackit", session: "s1", tier: "standard",
                       tokens: TokenCounts(input: 1, output: 1, cacheRead: 1), webSearches: 0, requests: 1),
        ])
        #expect(snapshot.limits?.windows == [CodexLimitWindow(usedPercent: 12.5, windowMinutes: 300, resetsAt: 1_794_315_600)])
        #expect(try AIUsageSnapshot(json: Data(#"{"generation":3,"files":1}"#.utf8)).rows == nil)
        #expect((try? AIUsageSnapshot(json: Data("nope".utf8))) == nil)
    }

    @Test func readsSyntheticLogsThroughTheRustCore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mackit-ai-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-600))
        let usage: [String: Any] = ["input_tokens": 300, "cached_input_tokens": 200, "output_tokens": 7]
        try write([[
            "type": "assistant", "timestamp": stamp, "sessionId": "s1", "requestId": "r1", "cwd": "/tmp/mackit",
            "message": ["id": "m1", "model": "claude-opus-5-5", "usage": ["input_tokens": 100, "output_tokens": 50, "cache_read_input_tokens": 1000,
                                                                           "cache_creation_input_tokens": 10, "service_tier": "standard"]],
        ]], to: root.appendingPathComponent("claude/p/s1.jsonl"))
        try write([
            ["timestamp": stamp, "type": "turn_context", "payload": ["cwd": "/tmp/api", "model": "gpt-5.2"]],
            ["timestamp": stamp, "type": "event_msg", "payload": [
                "type": "token_count", "info": ["total_token_usage": usage, "last_token_usage": usage],
                "rate_limits": ["primary": ["used_percent": 25, "window_minutes": 300, "resets_at": Int(now.timeIntervalSince1970) + 3600]],
            ]],
        ], to: root.appendingPathComponent("codex/2026/11/10/rollout.jsonl"))
        let paths = AIUsagePaths(cache: root.appendingPathComponent("support/ai-usage.cache"), claude: [root.appendingPathComponent("claude")],
                                 codex: [root.appendingPathComponent("codex")])
        let snapshot = try AIUsageSnapshot(json: RustCore.aiUsage(paths.request(now: now, known: 0)))
        let rows = try #require(snapshot.rows)
        #expect(snapshot.files == 2)
        #expect(rows.map(\.model).sorted() == ["claude-opus-5-5", "gpt-5.2"])
        #expect(rows.first { $0.agent == .codex }?.tokens == TokenCounts(input: 100, output: 7, cacheRead: 200))
        #expect(rows.first { $0.agent == .claude }?.tokens == TokenCounts(input: 100, output: 50, cacheRead: 1000, cacheWrite5m: 10))
        #expect(rows.first { $0.agent == .claude }?.project == "mackit")
        #expect(snapshot.limits?.primary?.usedPercent == 25)
        let unchanged = try AIUsageSnapshot(json: RustCore.aiUsage(paths.request(now: now, known: snapshot.generation)))
        #expect(unchanged.rows == nil && unchanged.generation == snapshot.generation)
        #expect(try AIUsageSnapshot(json: RustCore.aiUsage(paths.request(now: now, known: 0, release: true))).error == nil)
        #expect(FileManager.default.fileExists(atPath: paths.cache.path))
    }
}
