import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import CleanMacOS

struct TypingEngineTests {
    private func type(_ keys: String, into engine: TypingEngine = TypingEngine()) -> String {
        var screen = ""
        for scalar in keys.unicodeScalars {
            if let edit = engine.key(scalar) {
                screen.removeLast(min(edit.backspaces, screen.count))
                screen += edit.text
            } else {
                screen.unicodeScalars.append(scalar)
            }
        }
        return screen
    }

    @Test func typesVietnameseWithTelexByDefault() {
        #expect(type("Tieengs Vieetj ddepj ") == "Tiếng Việt đẹp ")
        #expect(type("windows ") == "windows ")
    }

    @Test func switchesToVNIAndOldToneStyle() {
        let engine = TypingEngine()
        engine.configure(TypingOptions(method: .vni, modernTone: false))
        #expect(type("hoa2 tie61ng", into: engine) == "hòa tiếng")
    }

    @Test func expandsMacrosEvenWhenVietnameseIsOff() {
        let engine = TypingEngine()
        engine.setMacros(["ko": "không", "vn": "Việt Nam"])
        #expect(type("ko vn ", into: engine) == "không Việt Nam ")
        engine.configure(TypingOptions(), vietnamese: false)
        #expect(type("tieengs ko ", into: engine) == "tieengs không ")
    }

    @Test func followsBackspaceAndRestoresTheRawKeys() {
        let engine = TypingEngine()
        #expect(type("ab", into: engine) == "ab")
        engine.backspace()
        #expect(engine.key("s") == TypingEdit(backspaces: 1, text: "á"))
        engine.reset()
        _ = type("vieejt", into: engine)
        #expect(engine.restore() == TypingEdit(backspaces: 4, text: "vieejt"))
        #expect(engine.finish(separator: nil) == nil)
    }

    @Test func packsOptionsIntoFlags() {
        #expect(TypingOptions().flags(vietnamese: true) == 0b0001_1110)
        #expect(TypingOptions(method: .vni, modernTone: false, autoRestore: false, wAsU: false, brackets: true,
                              foreignConsonants: true, autoCapitalize: true).flags(vietnamese: false) == 0b1110_0001)
    }
}

struct TypingPreferencesTests {
    @Test func remembersTheModePerAppAndSkipsExcludedApps() {
        var preferences = TypingPreferences()
        preferences.appModes = ["com.apple.Terminal": false]
        preferences.excludedApps = ["com.example.game"]
        #expect(preferences.mode(for: "com.apple.Terminal") == false)
        #expect(preferences.mode(for: "com.apple.Notes") == true)
        #expect(preferences.isExcluded("com.example.game"))
        #expect(!preferences.isExcluded(nil))
        preferences.remembersAppMode = false
        #expect(preferences.mode(for: "com.apple.Terminal") == true)
    }

    @Test func onlyEnabledMacrosReachTheEngine() {
        var preferences = TypingPreferences()
        #expect(preferences.activeMacros.isEmpty)
        preferences.macros[0].isEnabled = true
        #expect(preferences.activeMacros == ["vn": "Việt Nam"])
    }

    @Test func savesAndLoadsPreferences() throws {
        let suite = "typing-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TypingPreferencesStore(defaults: defaults)
        #expect(store.load() == TypingPreferences())
        var preferences = TypingPreferences()
        preferences.isEnabled = true
        preferences.options.method = .vni
        preferences.escRestores = true
        store.save(preferences)
        #expect(store.load() == preferences)
    }

    @Test func importsAndExportsMacroLists() {
        let macros = TypingMacro.parse("; my list\nko: không\nvn:Việt Nam\nbroken line\n:empty\n")
        #expect(macros.map(\.trigger) == ["ko", "vn"])
        #expect(macros.map(\.expansion) == ["không", "Việt Nam"])
        #expect(TypingMacro.export(macros) == "ko:không\nvn:Việt Nam\n")
    }
}

struct KeyHandlingTests {
    @Test func classifiesKeysForTheTypingEngine() {
        let letter: [UniChar] = [UniChar(UInt8(ascii: "a"))]
        #expect(KeyClassifier.classify(keyCode: kVK_ANSI_A, flags: [], characters: letter) == .type("a"))
        #expect(KeyClassifier.classify(keyCode: kVK_ANSI_A, flags: .maskShift, characters: [65]) == .type("A"))
        #expect(KeyClassifier.classify(keyCode: kVK_ANSI_A, flags: .maskCommand, characters: letter) == .reset)
        #expect(KeyClassifier.classify(keyCode: kVK_Delete, flags: [], characters: [8]) == .backspace)
        #expect(KeyClassifier.classify(keyCode: kVK_Return, flags: [], characters: [13]) == .commit)
        #expect(KeyClassifier.classify(keyCode: kVK_Tab, flags: [], characters: [9]) == .commit)
        #expect(KeyClassifier.classify(keyCode: kVK_Escape, flags: [], characters: [27]) == .escape)
        #expect(KeyClassifier.classify(keyCode: kVK_LeftArrow, flags: [], characters: []) == .reset)
        #expect(KeyClassifier.classify(keyCode: kVK_Space, flags: [], characters: [32]) == .type(" "))
    }

    @Test func picksAWritingStyleForEachKindOfApp() {
        #expect(InjectionStyle.style(for: "com.google.Chrome") == .browser)
        #expect(InjectionStyle.style(for: "com.apple.Terminal") == .slow)
        #expect(InjectionStyle.style(for: "com.jetbrains.intellij") == .slow)
        #expect(InjectionStyle.style(for: "com.adobe.Photoshop") == .characterByCharacter)
        #expect(InjectionStyle.style(for: "com.teamviewer.TeamViewer") == .passthrough)
        #expect(InjectionStyle.style(for: "com.apple.Notes") == .fast)
        #expect(InjectionStyle.style(for: nil) == .fast)
    }

    @Test func plansTheSyntheticKeysForAnEdit() {
        let edit = TypingEdit(backspaces: 2, text: "ếng")
        #expect(InjectionStyle.fast.plan(edit) == [.backspace, .backspace, .text("ếng")])
        #expect(InjectionStyle.browser.plan(edit) == [
            .text(InjectionStyle.autocompleteBreaker), .backspace, .pause(3000), .backspace, .pause(3000), .backspace, .pause(3000),
            .pause(8000), .text("ếng"), .pause(3000),
        ])
        #expect(InjectionStyle.characterByCharacter.plan(TypingEdit(backspaces: 0, text: "ư")) == [.text("ư")])
        #expect(InjectionStyle.characterByCharacter.plan(TypingEdit(backspaces: 1, text: "ếg")) == [.backspace, .text("ế"), .text("g")])
        #expect(InjectionStyle.browser.plan(TypingEdit(backspaces: 0, text: "ư")) == [.text("ư"), .pause(3000)])
    }
}
