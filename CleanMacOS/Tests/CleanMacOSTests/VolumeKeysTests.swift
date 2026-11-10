import CoreAudio
import Foundation
import Testing
@testable import CleanMacOS

struct VolumeKeysTests {
    @Test func soundSettingsSavedBeforeTheseOptionsStillDecode() throws {
        let saved = #"{"cycleEnabled":true,"cycleOutputs":["a"],"outputPriorityEnabled":false,"inputPriorityEnabled":false,"outputPriority":[],"#
            + #""inputPriority":[],"deviceNames":{},"micShortcutEnabled":false,"showsMicBadge":true,"handlesVolumeKeys":true,"volumeStep":"half","#
            + #""guardsHeadphones":false,"headphoneTarget":0.25,"blocksMusic":false}"#
        let settings = try JSONDecoder().decode(SoundSettings.self, from: Data(saved.utf8))
        #expect(settings.cycleEnabled && settings.cycleOutputs == ["a"] && settings.handlesVolumeKeys && settings.volumeStep == .half)
        #expect(!settings.playsFeedback && settings.usesMonitorSpeakers)
    }

    @Test func confirmsAVolumeWriteByReadingItBack() {
        #expect(VolumeWrite.isConfirmed(target: 0.5, readBack: 0.5))
        #expect(VolumeWrite.isConfirmed(target: 0.5, readBack: 0.51))
        #expect(!VolumeWrite.isConfirmed(target: 0.5, readBack: 0.3))
        #expect(!VolumeWrite.isConfirmed(target: 0.5, readBack: nil))
    }

    @Test func findsTheMonitorBehindADisplayAudioDevice() {
        let monitors = ["DELL P2422H", "LG HDR 4K"]
        #expect(MonitorSpeakers.match(deviceName: "LG HDR 4K", monitorNames: monitors) == 1)
        #expect(MonitorSpeakers.match(deviceName: " dell p2422h", monitorNames: monitors) == 0)
        #expect(MonitorSpeakers.match(deviceName: "Mac mini Speakers", monitorNames: monitors) == nil)
        #expect(MonitorSpeakers.match(deviceName: "DELL P2422H", monitorNames: ["DELL P2422H", "DELL P2422H"]) == nil)
        #expect(MonitorSpeakers.isDisplayAudio(transport: kAudioDeviceTransportTypeDisplayPort))
        #expect(MonitorSpeakers.isDisplayAudio(transport: kAudioDeviceTransportTypeHDMI))
        #expect(!MonitorSpeakers.isDisplayAudio(transport: kAudioDeviceTransportTypeBuiltIn))
    }

    @Test func togglesMonitorMuteWithTheVCPValues() {
        #expect(MonitorSpeakers.muteValue(isMuted: true) == 1)
        #expect(MonitorSpeakers.muteValue(isMuted: false) == 2)
    }
}
