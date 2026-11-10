import Foundation
import Testing
@testable import CleanMacOS

struct BrightnessFunctionKeysTests {
    @Test func mapsF14AndF15ToBrightness() {
        #expect(BrightnessKeys.functionKeyDirection(keyCode: BrightnessKeys.f14Key) == false)
        #expect(BrightnessKeys.functionKeyDirection(keyCode: BrightnessKeys.f15Key) == true)
        #expect(BrightnessKeys.functionKeyDirection(keyCode: 105) == nil)
    }

    @Test func brightnessSettingsSavedBeforeFunctionKeysStillDecode() throws {
        let saved = #"{"isEnabled":true,"handlesKeys":false,"keysFollowPointer":true,"step":"quarter","showsPercentage":false,"shortcutsEnabled":false,"#
            + #""keyboardShortcutsEnabled":false,"picturePreferred":["a"],"extraDimming":[],"xdrEnabled":false,"xdrLevel":1}"#
        let settings = try JSONDecoder().decode(BrightnessSettings.self, from: Data(saved.utf8))
        #expect(settings.isEnabled && !settings.handlesKeys && settings.keysFollowPointer && settings.step == .quarter && settings.picturePreferred == ["a"])
        #expect(!settings.usesFunctionKeys)
    }
}
