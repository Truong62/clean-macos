import AppKit
import Testing
@testable import CleanMacOS

struct EmojiCatalogTests {
    @Test func namesEmojiFromUnicode() {
        let entries = EmojiCatalog.entries
        #expect(entries.count > 1000)
        #expect(entries.contains { $0.glyph == "🔥" && $0.name == "fire" })
        #expect(entries.contains { $0.glyph == "❤️" && $0.name == "heavy black heart" })
        #expect(!entries.contains { $0.glyph.unicodeScalars.first.map { $0.isASCII || $0.properties.isEmojiModifier } ?? true })
        #expect(!entries.contains { $0.name.isEmpty })
    }

    @Test func readsTheColonPrefix() {
        #expect(EmojiCatalog.query(":fire") == "fire")
        #expect(EmojiCatalog.query(":  ") == "")
        #expect(EmojiCatalog.query("fire") == nil)
    }
}

struct FileSearchTests {
    @Test func buildsASpotlightNameQueryForEveryWord() {
        #expect(FileSearch.spotlightQuery("q") == nil)
        #expect(FileSearch.spotlightQuery("tax 2026") == #"kMDItemFSName == "*tax*"cd && kMDItemFSName == "*2026*"cd"#)
        #expect(FileSearch.spotlightQuery(#"a"b*"#) == #"kMDItemFSName == "*a\"b\**"cd"#)
    }

    @Test func skipsHiddenPackagedAndBuildFolders() {
        let root = "/Users/me/Projects"
        #expect(FileSearch.keeps("/Users/me/Projects/app/report.pdf", under: root))
        #expect(FileSearch.keeps("/Users/me/Projects/Tool.app", under: root))
        #expect(!FileSearch.keeps("/Users/me/Projects/.secret/notes.txt", under: root))
        #expect(!FileSearch.keeps("/Users/me/Projects/web/node_modules/x/index.js", under: root))
        #expect(!FileSearch.keeps("/Users/me/Projects/Tool.app/Contents/Info.plist", under: root))
        #expect(!FileSearch.keeps("/Users/me/Projects/ios/DerivedData/log.txt", under: root))
        #expect(!FileSearch.keeps("/Users/me/Elsewhere/file.txt", under: root))
    }
}

struct SelectedTextTests {
    @Test func changesCase() {
        let text = "hello wORLD. bye now"
        #expect(TextTransform.upper.apply(text) == "HELLO WORLD. BYE NOW")
        #expect(TextTransform.lower.apply(text) == "hello world. bye now")
        #expect(TextTransform.title.apply(text) == "Hello World. Bye Now")
        #expect(TextTransform.sentence.apply(text) == "Hello world. Bye now")
    }

    @Test func countsCharactersWordsAndLines() {
        let counts = TextCounts("one two\nthree")
        #expect(counts.characters == 13 && counts.words == 3 && counts.lines == 2)
        #expect(TextCounts("").lines == 0)
    }
}

struct CommandRowActionTests {
    private func item(_ kind: CommandKind, url: URL?) -> CommandRow {
        .item(CommandItem(id: "x", kind: kind, title: "X", subtitle: "", icon: .symbol("x"), revealURL: url) { _ in }, argument: nil)
    }

    @Test func offersActionsThatFitTheRow() {
        let url = URL(fileURLWithPath: "/Applications/Safari.app")
        #expect(CommandRowActions.kinds(for: item(.app, url: url), isPinned: false, isRunning: true) == [.run, .reveal, .copyPath, .quit, .pin])
        #expect(CommandRowActions.kinds(for: item(.action, url: nil), isPinned: true, isRunning: false) == [.run, .copyTitle, .unpin])
        #expect(CommandRowActions.kinds(for: .answer(CommandAnswer(kind: .calculation, title: "4", detail: "2+2", copyText: "4")), isPinned: false,
                                        isRunning: false) == [.run])
    }

    @Test func opensWithCommandK() {
        #expect(CommandBarKeys.command(keyCode: CommandBarKeys.kKey, modifiers: .command, queryIsEmpty: false) == .actions)
    }
}

struct CommandBarSettingsDecodingTests {
    @Test func settingsSavedBeforeFileSearchStillDecode() throws {
        let saved = #"{"isEnabled":true,"searchesWindows":false,"searchesMenus":true,"searchesSnippets":true,"searchesClipboard":true,"links":[]}"#
        let settings = try JSONDecoder().decode(CommandBarSettings.self, from: Data(saved.utf8))
        #expect(settings.isEnabled && !settings.searchesWindows && settings.fileFolders.isEmpty)
    }
}
