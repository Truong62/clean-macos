import Foundation
import Testing
@testable import CleanMacOS

struct LoginItemsTests {
    private func item(_ name: String, _ path: String?, enabled: Bool = true, missing: Bool = false) -> LoginItem {
        LoginItem(name: name, path: path, isEnabled: enabled, isMissing: missing)
    }

    @Test func mergeHidesOwnAppAndKeepsTurnedOffAppsSortedByName() {
        let enabled = [item("Zoom", "/Applications/zoom.us.app"), item("Clean macOS", "/Applications/Clean macOS.app"),
                       item("FigmaAgent", nil, missing: true)]
        let merged = LoginItemsService.merge(enabled: enabled,
                                             disabledPaths: ["/Applications/Slack.app", "/Applications/zoom.us.app"],
                                             ownPath: "/Applications/Clean macOS.app",
                                             fileExists: { $0 != "/Applications/Gone.app" })
        #expect(merged.map(\.name) == ["FigmaAgent", "Slack", "Zoom"])
        #expect(merged.map(\.isEnabled) == [true, false, true])
    }

    @Test func turnedOffAppThatWasUninstalledIsMarkedMissing() {
        let merged = LoginItemsService.merge(enabled: [], disabledPaths: ["/Applications/Gone.app"], ownPath: "",
                                             fileExists: { _ in false })
        #expect(merged == [item("Gone", "/Applications/Gone.app", enabled: false, missing: true)])
    }

    @Test func statusLabelAndIdentity() {
        #expect(item("A", "/A.app").statusLabel == "Opens at login")
        #expect(item("A", "/A.app", enabled: false).statusLabel == "Off")
        #expect(item("A", nil, missing: true).statusLabel == "App not found")
        #expect(item("A", "/A.app").id == "/A.app")
        #expect(item("A", nil).id == "A")
        #expect(LoginItemsService.displayName("/Applications/Foo Bar.app") == "Foo Bar")
    }
}
