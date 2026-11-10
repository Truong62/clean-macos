import AppKit
import Testing
@testable import CleanMacOS

struct SnippetMatcherTests {
    private func snippet(_ trigger: String, _ mode: Snippet.Mode = .afterDelimiter, ignoresCase: Bool = false, enabled: Bool = true) -> Snippet {
        Snippet(trigger: trigger, text: "expanded \(trigger)", mode: mode, isEnabled: enabled, ignoresCase: ignoresCase)
    }

    @Test func firesOnTheTriggerAtTheEndOfWhatWasTyped() {
        var matcher = SnippetMatcher()
        matcher.type("a;;dt")
        #expect(matcher.match(in: [snippet(";;dt")], mode: .afterDelimiter)?.trigger == ";;dt")
        #expect(matcher.match(in: [snippet(";;dt", .immediately)], mode: .afterDelimiter) == nil)
        #expect(matcher.match(in: [snippet(";;dt", enabled: false)], mode: .afterDelimiter) == nil)
    }

    @Test func firesRightAwayOnTheLastCharacter() {
        var matcher = SnippetMatcher()
        matcher.type(";;s")
        #expect(matcher.match(in: [snippet(";;sig", .immediately)], mode: .immediately, adding: "i") == nil)
        matcher.type("i")
        #expect(matcher.match(in: [snippet(";;sig", .immediately)], mode: .immediately, adding: "g")?.trigger == ";;sig")
    }

    @Test func handlesCaseBackspaceAndTheLongestTrigger() {
        var matcher = SnippetMatcher()
        matcher.type("xADDR")
        #expect(matcher.match(in: [snippet("addr")], mode: .afterDelimiter) == nil)
        #expect(matcher.match(in: [snippet("addr", ignoresCase: true)], mode: .afterDelimiter)?.trigger == "addr")
        matcher.type("x")
        matcher.backspace()
        #expect(matcher.match(in: [snippet("dr"), snippet("addr", ignoresCase: true)], mode: .afterDelimiter)?.trigger == "addr")
        matcher.reset()
        #expect(matcher.buffer.isEmpty)
    }

    @Test func keepsOnlyTheLastCharacters() {
        var matcher = SnippetMatcher()
        matcher.type(String(repeating: "a", count: 100) + "zz")
        #expect(matcher.buffer.count == SnippetMatcher.limit)
        #expect(matcher.buffer.hasSuffix("zz"))
    }

    @Test func sortsKeysIntoWhatTheyDoToTheBuffer() {
        #expect(SnippetKeys.classify(keyCode: 0, flags: [], characters: "a") == .character("a"))
        #expect(SnippetKeys.classify(keyCode: 0, flags: .maskAlternate, characters: "å") == .character("å"))
        #expect(SnippetKeys.classify(keyCode: 0, flags: .maskCommand, characters: "a") == .reset)
        #expect(SnippetKeys.classify(keyCode: 8, flags: .maskControl, characters: "c") == .reset)
        #expect(SnippetKeys.classify(keyCode: 123, flags: [], characters: "") == .reset)
        #expect(SnippetKeys.classify(keyCode: 53, flags: [], characters: "\u{1B}") == .reset)
        #expect(SnippetKeys.classify(keyCode: 51, flags: [], characters: "\u{7F}") == .backspace)
        #expect(SnippetKeys.classify(keyCode: 49, flags: [], characters: " ") == .delimiter)
        #expect(SnippetKeys.classify(keyCode: 48, flags: [], characters: "\t") == .delimiter)
        #expect(SnippetKeys.classify(keyCode: 36, flags: .maskShift, characters: "\r") == .delimiter)
    }
}

struct SnippetTemplateTests {
    private let now = Date(timeIntervalSince1970: 1_794_301_500)
    private let utc = TimeZone(identifier: "UTC")!
    private let english = Locale(identifier: "en_US")

    private func render(_ text: String, clipboard: String? = nil) -> String {
        SnippetTemplate.render(text, now: now, locale: english, timeZone: utc) { clipboard }.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    @Test func fillsDatesAndTimes() {
        #expect(render("{{date:yyyy-MM-dd}}") == "2026-11-10")
        #expect(render("at {{time:HH:mm}}!") == "at 09:05!")
        #expect(render("{{date}}") == "Nov 10, 2026")
        #expect(render("{{time}}") == "9:05 AM")
        #expect(render("{{datetime}}") == "Nov 10, 2026 9:05 AM")
        #expect(render("{{date-tz(Asia/Ho_Chi_Minh):HH:mm}}") == "16:05")
    }

    @Test func leavesUnknownOrBrokenTagsAlone() {
        #expect(render("{{date-tz(Mars/Base):HH:mm}}") == "{{date-tz(Mars/Base):HH:mm}}")
        #expect(render("{{date-tz(Asia/Ho_Chi_Minh)}}") == "{{date-tz(Asia/Ho_Chi_Minh)}}")
        #expect(render("{{weather}} {{date") == "{{weather}} {{date")
    }

    @Test func insertsTheClipboardWithoutExpandingIt() {
        #expect(render("Re: {{clipboard}}", clipboard: "{{date}}") == "Re: {{date}}")
        #expect(render("[{{clipboard}}]") == "[]")
        var reads = 0
        _ = SnippetTemplate.render("{{clipboard}}{{clipboard}}", now: now, locale: english, timeZone: utc) {
            reads += 1
            return "x"
        }
        #expect(reads == 1)
        _ = SnippetTemplate.render("no tags", now: now, locale: english, timeZone: utc) {
            reads += 1
            return "x"
        }
        #expect(reads == 1)
    }
}

struct SnippetLibraryTests {
    @Test func cleansUpTriggers() {
        #expect(Snippet.normalizedTrigger(" ; ; dt \n") == ";;dt")
        #expect(Snippet.normalizedTrigger(String(repeating: "x", count: 50)).count == Snippet.maxTrigger)
    }

    @Test func tidiesASnippetBeforeSaving() {
        let raw = Snippet(name: "  Address ", trigger: " ;; addr ", text: "1 Main St", folder: " Home ")
        let cleaned = raw.cleaned()
        #expect(cleaned.name == "Address")
        #expect(cleaned.trigger == ";;addr")
        #expect(cleaned.folder == "Home")
        #expect(cleaned.id == raw.id && cleaned.text == raw.text)
    }

    @Test func explainsWhyASnippetCannotBeSaved() {
        let existing = [Snippet(trigger: "addr", text: "1 Main St", ignoresCase: true)]
        #expect(SnippetLibrary.problem(with: Snippet(trigger: "a", text: "x"), among: existing) == .triggerTooShort)
        #expect(SnippetLibrary.problem(with: Snippet(trigger: "ADDR", text: "x"), among: existing) == .duplicateTrigger)
        #expect(SnippetLibrary.problem(with: Snippet(trigger: "sig", text: "  "), among: existing) == .emptyText)
        #expect(SnippetLibrary.problem(with: Snippet(trigger: "sig", text: "Best"), among: existing) == nil)
        #expect(SnippetLibrary.problem(with: existing[0], among: existing) == nil)
    }

    @Test func groupsTheLibraryByFolder() {
        let snippets = [
            Snippet(name: "Sign-off", trigger: "sig", text: "Best", folder: "Mail"),
            Snippet(trigger: "addr", text: "1 Main St"),
            Snippet(name: "Hello", trigger: "hi", text: "Hello there", folder: "Mail"),
            Snippet(name: "Code", trigger: "cb", text: "```", folder: "Dev"),
            Snippet(name: "Hidden", trigger: "hid", text: "x", showsInLibrary: false),
            Snippet(name: "Off", trigger: "off", text: "x", isEnabled: false),
        ]
        let sections = SnippetLibrary.sections(snippets, query: "")
        #expect(sections.map(\.folder) == ["Dev", "Mail", ""])
        #expect(sections[1].snippets.map(\.title) == ["Hello", "Sign-off"])
        #expect(SnippetLibrary.sections(snippets, query: "main").flatMap(\.snippets).map(\.trigger) == ["addr"])
        #expect(SnippetLibrary.sections(snippets, query: "mail").flatMap(\.snippets).count == 2)
    }
}
