import Foundation
import Testing
@testable import CleanMacOS

struct DDCPacketTests {
    @Test func encodesSetAndGetRequestsWithChecksums() {
        #expect(DDC.setPacket(code: DDC.brightness, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        #expect(DDC.getPacket(code: DDC.brightness) == [0x82, 0x01, 0x10, 0xAC])
    }

    @Test func readsOnlyValidRepliesForTheCodeAsked() {
        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00]
        reply[10] = reply[0..<10].reduce(0x50, ^)
        #expect(DDC.parseReply(reply, code: DDC.brightness) == DDCReading(current: 50, maximum: 100))
        #expect(DDC.parseReply(reply, code: DDC.volume) == nil)
        var corrupt = reply
        corrupt[9] = 0x33
        #expect(DDC.parseReply(corrupt, code: DDC.brightness) == nil)
        var failed = reply
        failed[3] = 0x01
        failed[10] = failed[0..<10].reduce(0x50, ^)
        #expect(DDC.parseReply(failed, code: DDC.brightness) == nil)
        #expect(DDC.parseReply(Array(reply.prefix(8)), code: DDC.brightness) == nil)
    }

    @Test func mapsMonitorValuesToTheSlider() {
        #expect(DDCReading(current: 30, maximum: 0).level == 0.3)
        #expect(DDCReading(current: 128, maximum: 255).level == 128.0 / 255)
        #expect(DDC.value(for: 0.5, maximum: 255) == 128)
        #expect(DDC.value(for: 2, maximum: 100) == 100)
        #expect(DDC.value(for: 0.37, maximum: 0) == 37)
    }
}

struct BrightnessMathTests {
    @Test func stepsOnAGridAndClamps() {
        #expect(LevelStep.standard.next(from: 0.5, up: true) == 0.5625)
        #expect(LevelStep.standard.next(from: 0.52, up: false) == 0.5)
        #expect(LevelStep.quarter.next(from: 0.5, up: true) == 0.515625)
        #expect(LevelStep.standard.next(from: 0.99, up: true) == 1)
        #expect(LevelStep.half.next(from: 0.01, up: false) == 0)
    }

    @Test func splitsExtraDimmingBelowTheHardwareMinimum() {
        #expect(BrightnessSplit(level: 0.1, extraDimming: true) == BrightnessSplit(hardware: 0, picture: 0.4))
        #expect(BrightnessSplit(level: 0.625, extraDimming: true) == BrightnessSplit(hardware: 0.5, picture: 1))
        #expect(BrightnessSplit(level: 0.1, extraDimming: false) == BrightnessSplit(hardware: 0.1, picture: 1))
        #expect(BrightnessSplit.level(hardware: 0.5, extraDimming: true) == 0.625)
        #expect(BrightnessSplit.level(hardware: 0.5, extraDimming: false) == 0.5)
    }

    @Test func scalesGammaAndRestoresTheOriginalAtFull() {
        let original = GammaTable(red: [0, 0.5, 1], green: [0, 0.4, 0.9], blue: [0.1, 0.5, 1])
        #expect(original.scaled(by: 0.5) == GammaTable(red: [0, 0.25, 0.5], green: [0, 0.2, 0.45], blue: [0.05, 0.25, 0.5]))
        #expect(original.scaled(by: 0.9995) == original)
        #expect(original.scaled(by: 0).red == [0, 0, 0])
    }

    @Test func boostsXDRWithinTheHeadroom() {
        let model = XDRModel(reference: 2.66, bonus: 0.48)
        #expect(abs(model.factor(level: 1, headroom: 2.66, potential: 3.2) - 1.48) < 0.0001)
        #expect(abs(model.factor(level: 0.5, headroom: 1.33, potential: 3.2) - 1.12) < 0.0001)
        #expect(model.factor(level: 1, headroom: 1.2, potential: 3.2) == 1.2)
        #expect(model.factor(level: 1, headroom: 1, potential: 3.2) == XDRModel.nudge)
        #expect(model.factor(level: 1, headroom: 2, potential: 1.04) == 1)
    }

    @Test func easesTheBoostUpAndDown() {
        #expect(abs(XDRModel.smooth(current: 1, target: 1.5) - 1.03) < 0.0001)
        #expect(abs(XDRModel.smooth(current: 1.5, target: 1.1) - 1.4) < 0.0001)
        #expect(XDRModel.smooth(current: 1.105, target: 1.1) == 1.1)
    }

    @Test func readsBrightnessKeysFromSystemEvents() {
        #expect(MediaKey(data1: (2 << 16) | (0x0A << 8)) == MediaKey(code: 2, isDown: true, isRepeat: false))
        #expect(MediaKey(data1: (3 << 16) | (0x0B << 8)) == MediaKey(code: 3, isDown: false, isRepeat: false))
        #expect(MediaKey(data1: (2 << 16) | (0x0A << 8) | 1)?.isRepeat == true)
        #expect(MediaKey(data1: (2 << 16) | (0x05 << 8)) == nil)
    }

    @Test func pairsMonitorsWithTheirI2CServices() {
        let monitors = [
            MonitorIdentity(vendor: 0x10AC, product: 0xA0C5, serial: 1, name: "DELL U2720Q", location: "a"),
            MonitorIdentity(vendor: 0x1E6D, product: 0x5B10, serial: 7, name: "LG HDR 4K", location: "b"),
        ]
        let services = [
            MonitorIdentity(vendor: 0x1E6D, product: 0x5B10, serial: 7, name: "LG HDR 4K", location: "b"),
            MonitorIdentity(vendor: 0x10AC, product: 0xA0C5, serial: 1, name: "DELL U2720Q", location: "x"),
        ]
        #expect(MonitorMatcher.pair(monitors, with: services) == [0: 1, 1: 0])
        #expect(MonitorMatcher.pair([monitors[0]], with: [MonitorIdentity(vendor: 1, product: 2, serial: 3, name: "?", location: "z")]) == [0: 0])
        #expect(MonitorMatcher.pair(monitors, with: []).isEmpty)
    }
}

struct BrightnessDecisionTests {
    @Test func picksTheBestWayToControlEachDisplay() {
        let reading = DDCReading(current: 40, maximum: 100)
        #expect(BrightnessRoute.choose(systemLevel: 0.6, probe: .none, forcesPicture: false) == .system)
        #expect(BrightnessRoute.choose(systemLevel: 0.6, probe: .none, forcesPicture: true) == .system)
        #expect(BrightnessRoute.choose(systemLevel: nil, probe: .live(reading), forcesPicture: false) == .ddc)
        #expect(BrightnessRoute.choose(systemLevel: nil, probe: .writeOnly, forcesPicture: false) == .ddc)
        #expect(BrightnessRoute.choose(systemLevel: nil, probe: .none, forcesPicture: false) == .picture)
        #expect(BrightnessRoute.choose(systemLevel: nil, probe: .live(reading), forcesPicture: true) == .picture)
    }

    @Test func leavesTheBuiltInScreenAndModifiedKeysToMacOS() {
        #expect(!BrightnessKeys.handles(route: .system, isBuiltIn: true))
        #expect(BrightnessKeys.handles(route: .system, isBuiltIn: false))
        #expect(BrightnessKeys.handles(route: .ddc, isBuiltIn: false))
        #expect(BrightnessKeys.step(for: [], default: .standard) == .standard)
        #expect(BrightnessKeys.step(for: [.maskAlternate, .maskShift], default: .standard) == .quarter)
        #expect(BrightnessKeys.step(for: .maskAlternate, default: .standard) == nil)
        #expect(BrightnessKeys.step(for: .maskCommand, default: .half) == nil)
        #expect(BrightnessKeys.step(for: .maskControl, default: .half) == nil)
    }

    @Test func keysSettingsByTheMonitorItself() {
        #expect(MonitorIdentity(vendor: 0x10AC, product: 0xA0C5, serial: 1, name: "DELL", location: "x").key == "10ac:a0c5:1")
        #expect(MonitorIdentity(vendor: 0, product: 0, serial: 0, name: "Display", location: "p/1").key == "Display@p/1")
    }
}
