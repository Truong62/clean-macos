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
        engine.configure(TypingOptions(method: .vni, modernTone: false, autoRestore: true, wAsU: true))
        #expect(type("hoa2 tie61ng", into: engine) == "hòa tiếng")
    }

    @Test func expandsMacrosAndFollowsBackspace() {
        let engine = TypingEngine()
        engine.setMacros(["ko": "không", "vn": "Việt Nam"])
        #expect(type("ko vn ", into: engine) == "không Việt Nam ")
        engine.reset()
        #expect(type("ab", into: engine) == "ab")
        engine.backspace()
        #expect(engine.key("s") == TypingEdit(backspaces: 1, text: "á"))
        #expect(engine.finish(separator: nil) == nil)
    }
}

struct TypingPreferencesTests {
    @Test func remembersTheModePerAppAndSkipsExcludedApps() {
        var preferences = TypingPreferences()
        preferences.isVietnamese = true
        preferences.appModes = ["com.apple.Terminal": false]
        preferences.excludedApps = ["com.example.game"]
        #expect(preferences.mode(for: "com.apple.Terminal") == false)
        #expect(preferences.mode(for: "com.apple.Notes") == true)
        #expect(preferences.mode(for: nil) == true)
        #expect(preferences.isExcluded("com.example.game"))
        #expect(!preferences.isExcluded(nil))
        preferences.remembersAppMode = false
        #expect(preferences.mode(for: "com.apple.Terminal") == true)
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
        preferences.macros = ["ko": "không"]
        store.save(preferences)
        #expect(store.load() == preferences)
    }

    @Test func classifiesKeysForTheTypingEngine() {
        let letter: [UniChar] = [UniChar(UInt8(ascii: "a"))]
        #expect(KeyClassifier.classify(keyCode: kVK_ANSI_A, flags: [], characters: letter) == .type("a"))
        #expect(KeyClassifier.classify(keyCode: kVK_ANSI_A, flags: .maskShift, characters: [65]) == .type("A"))
        #expect(KeyClassifier.classify(keyCode: kVK_ANSI_A, flags: .maskCommand, characters: letter) == .reset)
        #expect(KeyClassifier.classify(keyCode: kVK_Delete, flags: [], characters: [8]) == .backspace)
        #expect(KeyClassifier.classify(keyCode: kVK_Return, flags: [], characters: [13]) == .reset)
        #expect(KeyClassifier.classify(keyCode: kVK_Space, flags: [], characters: [32]) == .type(" "))
        #expect(KeyClassifier.classify(keyCode: kVK_F5, flags: [], characters: []) == .reset)
    }
}
