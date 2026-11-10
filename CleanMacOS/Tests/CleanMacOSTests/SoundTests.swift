import Foundation
import Testing
@testable import CleanMacOS

struct SoundLogicTests {
    @Test func cyclesThroughTickedOutputs() {
        let available = ["speakers", "headphones", "tv", "monitor"]
        #expect(DeviceCycle.next(after: "speakers", in: available, ticked: ["speakers", "tv"]) == "tv")
        #expect(DeviceCycle.next(after: "tv", in: available, ticked: ["speakers", "tv"]) == "speakers")
        #expect(DeviceCycle.next(after: "headphones", in: available, ticked: ["speakers", "tv"]) == "tv")
        #expect(DeviceCycle.next(after: "tv", in: available, ticked: ["tv"]) == nil)
        #expect(DeviceCycle.next(after: nil, in: available, ticked: ["monitor", "gone"]) == "monitor")
    }

    @Test func seedsAndPlacesDevicesInPriorityLists() {
        let kinds: [String: SoundDevice.Kind] = ["virtual": .virtual, "usb": .hardware, "builtin": .builtIn, "bt": .hardware]
        #expect(AudioPriority.seed(current: "bt", devices: ["virtual", "usb", "builtin", "bt"], kinds: kinds) == ["bt", "builtin", "usb", "virtual"])
        let list = ["usb", "builtin", "virtual"]
        #expect(AudioPriority.placing("new", in: list, kinds: kinds, becameDefault: false) == ["usb", "builtin", "new", "virtual"])
        #expect(AudioPriority.placing("other", in: list, kinds: kinds, becameDefault: true).first == "other")
        #expect(AudioPriority.placing("usb", in: list, kinds: kinds, becameDefault: true) == list)
        #expect(AudioPriority.placing("new", in: ["usb"], kinds: kinds, becameDefault: false) == ["usb", "new"])
    }

    @Test func picksTheFirstAvailableDeviceButNeverOverridesAnUnplacedOne() {
        let list = ["usb", "builtin", "virtual"]
        #expect(AudioPriority.choice(in: list, available: ["builtin", "virtual"], current: "virtual") == "builtin")
        #expect(AudioPriority.choice(in: list, available: ["builtin", "virtual"], current: "builtin") == nil)
        #expect(AudioPriority.choice(in: list, available: ["builtin", "fresh"], current: "fresh") == nil)
        #expect(AudioPriority.choice(in: list, available: [], current: nil) == nil)
    }

    @Test func mutesOnlyMicrophonesTheUserLeftOn() {
        let states = [
            "mic": InputControlState(mutes: [0: 0], volumes: [0: 0.6]),
            "muted": InputControlState(mutes: [0: 1], volumes: [0: 0.5]),
            "quiet": InputControlState(mutes: [:], volumes: [1: 0, 2: 0]),
        ]
        #expect(MicMutePlan.newClaims(from: states, existing: [:]).keys.sorted() == ["mic"])
        #expect(MicMutePlan.newClaims(from: states, existing: ["mic": states["mic"]!]).isEmpty)
        #expect(InputControlState(mutes: [0: 0, 1: 0], volumes: [0: 0.6]).silenced == InputControlState(mutes: [0: 1, 1: 1], volumes: [0: 0]))
    }

    @Test func recognisesHeadphones() {
        #expect(HeadphoneDetector.isHeadphones(name: "AirPods Pro", uid: "x", terminal: 0))
        #expect(HeadphoneDetector.isHeadphones(name: "External Headphones", uid: "BuiltInHeadphoneOutputDevice", terminal: 0))
        #expect(HeadphoneDetector.isHeadphones(name: "USB Audio", uid: "u", terminal: HeadphoneDetector.headphoneTerminal))
        #expect(!HeadphoneDetector.isHeadphones(name: "Mac mini Speakers", uid: "BuiltInSpeakerDevice", terminal: HeadphoneDetector.speakerTerminal))
        #expect(!HeadphoneDetector.isHeadphones(name: "Beats Pill", uid: "b", terminal: HeadphoneDetector.speakerTerminal))
    }

    @Test func lowersTheSpeakersWhenHeadphonesGoAndPutsThemBack() {
        var headphoneGuard = HeadphoneGuard(target: 0.25)
        #expect(headphoneGuard.disconnected(to: "speakers", volume: 0.8) == 0.25)
        #expect(headphoneGuard.reconnected { $0 == "speakers" ? 0.25 : nil } == SoundLevel(device: "speakers", volume: 0.8))
        #expect(headphoneGuard.disconnected(to: "speakers", volume: 0.1) == nil)
        _ = headphoneGuard.disconnected(to: "speakers", volume: 0.9)
        #expect(headphoneGuard.reconnected { _ in 0.5 } == nil)
    }

    @Test func blocksMusicOnlyRightAfterAMediaKey() {
        #expect(MusicBlocker.shouldBlock(launchedAt: 10, lastMediaKey: 9))
        #expect(!MusicBlocker.shouldBlock(launchedAt: 10, lastMediaKey: 7.5))
        #expect(!MusicBlocker.shouldBlock(launchedAt: 10, lastMediaKey: nil))
    }
}
