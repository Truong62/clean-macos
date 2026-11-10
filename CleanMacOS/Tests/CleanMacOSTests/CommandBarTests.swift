import Foundation
import Testing
@testable import CleanMacOS

struct CommandMemoryTests {
    private let now = Date(timeIntervalSince1970: 1_794_301_500)

    @Test func boostsRecentlyAndOftenUsedRows() {
        var memory = CommandMemory(salt: "s")
        for _ in 0..<3 { memory.recordRun("app.safari", query: "", at: now) }
        #expect(memory.usageBoost(for: "app.safari", now: now.addingTimeInterval(3600)) == 3 * 12)
        #expect(memory.usageBoost(for: "app.safari", now: now.addingTimeInterval(86_400)) == 3 * 8)
        #expect(memory.usageBoost(for: "app.safari", now: now.addingTimeInterval(5 * 86_400)) == 3 * 5)
        #expect(memory.usageBoost(for: "app.safari", now: now.addingTimeInterval(30 * 86_400)) == 3 * 2)
        #expect(memory.usageBoost(for: "app.other", now: now) == 0)
        for _ in 0..<60 { memory.recordRun("app.safari", query: "", at: now) }
        #expect(memory.usageBoost(for: "app.safari", now: now) == 40 * 12)
    }

    @Test func learnsWhichRowATypedPrefixMeans() {
        var memory = CommandMemory(salt: "s")
        memory.recordRun("app.slack", query: "sl", at: now)
        memory.recordRun("app.slack", query: "sl", at: now)
        #expect(memory.priority(for: "app.slack", query: "sla") == 2 * 5 + 2 * 6)
        #expect(memory.priority(for: "app.slack", query: "x") == 0)
        #expect(memory.priority(for: "app.safari", query: "sl") == 0)
        #expect(!memory.learned.keys.contains("sl"))
    }

    @Test func keepsPinsInOrderAndWithinLimits() {
        var memory = CommandMemory(salt: "s")
        memory.togglePin("a")
        memory.togglePin("b")
        #expect(memory.pins == ["a", "b"])
        memory.togglePin("a")
        #expect(memory.pins == ["b"])
        for index in 0..<40 { memory.togglePin("p\(index)") }
        #expect(memory.pins.count == CommandMemory.maxPins)
    }
}

struct CommandRankingTests {
    @Test func capsEachKindAndTheTotal() {
        let kinds: [CommandKind] = Array(repeating: .app, count: 8) + Array(repeating: .action, count: 10) + [.setting, .setting, .setting, .setting, .setting]
        let kept = CommandRanking.capped(kinds)
        #expect(kept.count == CommandRanking.totalLimit)
        #expect(kept.filter { kinds[$0] == .app }.count == 5)
        #expect(kept.first == 0)
    }

    @Test func splitsATrailingNumberArgument() {
        #expect(CommandArgument.split("brightness 40") == CommandArgument(text: "brightness", number: 40))
        #expect(CommandArgument.split("volume 75%") == CommandArgument(text: "volume", number: 75))
        #expect(CommandArgument.split("brightness") == nil)
        #expect(CommandArgument.split("40") == nil)
    }

    @Test func expandsLinkTemplates() {
        let date = Date(timeIntervalSince1970: 1_794_301_500)
        let link = CommandLink(name: "GitHub", keyword: "gh", template: "https://github.com/search?q={query}&d={date}")
        #expect(link.url(query: "swift ui", clipboard: nil, selection: nil, date: date, timeZone: TimeZone(identifier: "UTC")!)?.absoluteString
            == "https://github.com/search?q=swift%20ui&d=2026-11-10")
        #expect(CommandLink(name: "Clip", keyword: "c", template: "https://x.com/{clipboard}").url(query: "", clipboard: "a b", selection: nil, date: date)?.absoluteString
            == "https://x.com/a%20b")
        #expect(CommandLink.match("gh swift", links: [link])?.query == "swift")
        #expect(CommandLink.match("github", links: [link]) == nil)
    }
}

struct CommandAnswerTests {
    private let english = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_794_301_500)
    private let utc = TimeZone(identifier: "UTC")!

    private func answers(_ query: String) -> [CommandAnswer] {
        CommandAnswers.answers(for: query, locale: english, now: now, timeZone: utc)
    }

    @Test func calculatesAndConverts() {
        #expect(answers("2+2*3").first == CommandAnswer(kind: .calculation, title: "8", detail: "2+2*3", copyText: "8"))
        #expect(answers("(1+2").first?.detail == "(1+2) · added 1 closing bracket")
        #expect(answers("100 km to mi").first == CommandAnswer(kind: .conversion, title: "62.14 mi", detail: "100 km", copyText: "62.14 mi"))
        #expect(answers("hello").isEmpty)
    }

    @Test func understandsColorsLinksAndDates() {
        #expect(answers("#ff0000").first?.kind == .color)
        #expect(answers("#ff0000").first?.detail == "rgb(255, 0, 0) · hsl(0, 100%, 50%)")
        #expect(answers("example.com/path").first == CommandAnswer(kind: .link, title: "Open example.com/path", detail: "https://example.com/path", copyText: "https://example.com/path"))
        #expect(answers("in 3 weeks").first?.title == "Tuesday, December 1, 2026")
        #expect(answers("2 days ago").first?.title == "Sunday, November 8, 2026")
        #expect(answers("time in tokyo").first?.title.hasPrefix("6:05") == true)
        #expect(answers("time in atlantis").isEmpty)
    }
}

struct CommandBarKeyTests {
    @Test func mapsKeysToCommands() {
        #expect(CommandBarKeys.command(keyCode: 125, modifiers: [.numericPad, .function], queryIsEmpty: false) == .move(1))
        #expect(CommandBarKeys.command(keyCode: 35, modifiers: .control, queryIsEmpty: false) == .move(-1))
        #expect(CommandBarKeys.command(keyCode: 35, modifiers: .command, queryIsEmpty: false) == .pin)
        #expect(CommandBarKeys.command(keyCode: 36, modifiers: [], queryIsEmpty: false) == .run)
        #expect(CommandBarKeys.command(keyCode: 36, modifiers: .command, queryIsEmpty: false) == .reveal)
        #expect(CommandBarKeys.command(keyCode: 48, modifiers: [], queryIsEmpty: false) == .complete)
        #expect(CommandBarKeys.command(keyCode: 19, modifiers: .command, queryIsEmpty: false) == .runNumber(2))
        #expect(CommandBarKeys.command(keyCode: 124, modifiers: [], queryIsEmpty: true) == .category(1))
        #expect(CommandBarKeys.command(keyCode: 124, modifiers: [], queryIsEmpty: false) == nil)
        #expect(CommandBarKeys.command(keyCode: 12, modifiers: .command, queryIsEmpty: false) == .blocked)
        #expect(CommandBarKeys.command(keyCode: 53, modifiers: [], queryIsEmpty: false) == .escape)
        #expect(CommandBarKeys.command(keyCode: 0, modifiers: [], queryIsEmpty: false) == nil)
    }
}

@MainActor
struct CommandSourceTests {
    @Test func findsAndRanksInstalledApps() {
        let apps = CommandSources.installedApps()
        #expect(apps.contains { $0.name == "Safari" })
        let rows = apps.map { RankRow(title: $0.name, keywords: $0.url.deletingPathExtension().lastPathComponent) }
        #expect(RustCore.rank("safari", rows).first.map { apps[$0.index].name } == "Safari")
        #expect(RustCore.rank("safri", rows).first.map { apps[$0.index].name } == "Safari")
        #expect(MacSettingsPane.all.count == Set(MacSettingsPane.all.map(\.id)).count)
    }
}
