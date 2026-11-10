import Foundation
import Testing
@testable import CleanMacOS

final class FakeAssertion: PowerAssertionProviding {
    private(set) var held: [String] = []
    private(set) var releases = 0
    private var next: UInt32 = 1

    func hold(displayOn: Bool, reason: String) -> UInt32? {
        held.append(displayOn ? "display" : "system")
        defer { next += 1 }
        return next
    }

    func release(_ id: UInt32) {
        releases += 1
    }
}

struct KeepAwakeRuleTests {
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func computesTheEndOfEachDuration() {
        #expect(KeepAwakeDuration.minutes(15).end(from: noon) == noon.addingTimeInterval(900))
        #expect(KeepAwakeDuration.indefinitely.end(from: noon) == nil)
        let later = noon.addingTimeInterval(3 * 3600)
        #expect(KeepAwakeDuration.until(later).end(from: noon) == later)
        #expect(KeepAwakeDuration.until(noon.addingTimeInterval(-60)).end(from: noon) == nil)
    }

    @Test func stopsWhenTimeIsUpOrTheBatteryIsLow() {
        let session = KeepAwakeSession(started: noon, ends: noon.addingTimeInterval(600), isAutomatic: false)
        let fine = PowerState(onBattery: true, batteryPercent: 50, externalDisplay: false, screenLocked: false)
        #expect(session.stopReason(now: noon.addingTimeInterval(60), power: fine, minimumBattery: 10) == nil)
        #expect(session.stopReason(now: noon.addingTimeInterval(601), power: fine, minimumBattery: 10) == .timeUp)
        let low = PowerState(onBattery: true, batteryPercent: 9, externalDisplay: false, screenLocked: false)
        #expect(session.stopReason(now: noon, power: low, minimumBattery: 10) == .lowBattery)
        let charging = PowerState(onBattery: false, batteryPercent: 5, externalDisplay: false, screenLocked: false)
        #expect(session.stopReason(now: noon, power: charging, minimumBattery: 10) == nil)
        #expect(session.remaining(now: noon.addingTimeInterval(120)) == 480)
    }

    @Test func automaticRulesMatchAnyOrAllConditions() {
        var rules = KeepAwakeRules()
        let power = PowerState(onBattery: false, batteryPercent: 80, externalDisplay: true, screenLocked: false)
        #expect(!rules.matches(power: power, runningApps: []))
        rules.whenOnPower = true
        rules.whenExternalDisplay = true
        #expect(rules.matches(power: power, runningApps: []))
        rules.apps = ["com.apple.Keynote"]
        rules.requireAll = true
        #expect(!rules.matches(power: power, runningApps: ["com.apple.Safari"]))
        #expect(rules.matches(power: power, runningApps: ["com.apple.Keynote"]))
        rules.requireAll = false
        #expect(rules.matches(power: PowerState(onBattery: true, batteryPercent: 80, externalDisplay: false, screenLocked: false),
                              runningApps: ["com.apple.Keynote"]))
    }

    @Test func formatsTheCountdown() {
        #expect(KeepAwakeSession.countdown(3725) == "1:02:05")
        #expect(KeepAwakeSession.countdown(65) == "1:05")
    }
}

@MainActor
struct KeepAwakeServiceTests {
    @Test func holdsOneAssertionAndReleasesItOnStop() throws {
        let suite = "keep-awake-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let assertion = FakeAssertion()
        let service = KeepAwake(assertion: assertion, defaults: defaults, power: { PowerState(onBattery: false, batteryPercent: 100, externalDisplay: false, screenLocked: false) }, runningApps: { [] })
        service.start(.minutes(30))
        #expect(service.isActive)
        #expect(assertion.held == ["display"])
        service.extend(by: 900)
        #expect(service.session?.ends == service.session?.started.addingTimeInterval(2700))
        service.start(.indefinitely)
        #expect(assertion.held.count == 1)
        service.stop()
        #expect(!service.isActive)
        #expect(assertion.releases == 1)
    }
}
