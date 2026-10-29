import CoreMedia
import Foundation
import Testing
@testable import CleanMacOS

@MainActor
struct RecordingMCPServerTests {
    private let server = RecordingMCPServer(session: AgentRecordingSession())

    private func call(_ line: String) async throws -> [String: Any] {
        let data = try #require(await server.reply(to: line))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func initializeEchoesTheClientProtocolVersion() async throws {
        let reply = try await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        let result = try #require(reply["result"] as? [String: Any])
        #expect(reply["id"] as? Int == 1)
        #expect(result["protocolVersion"] as? String == "2025-03-26")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    @Test func listsTheRecordingAndDemoTools() async throws {
        let reply = try await call(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names.count == 15)
        #expect(Set(names).isSuperset(of: ["list_sources", "start_recording", "stop_recording", "annotate", "caption", "click", "zoom_in", "screenshot"]))
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        #expect(reply["id"] as? String == "a")
    }

    @Test func ignoresNotificationsAndRejectsUnknownMethods() async throws {
        #expect(await server.reply(to: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let reply = try await call(#"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#)
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32601)
        let broken = try await call("not json")
        #expect((broken["error"] as? [String: Any])?["code"] as? Int == -32700)
    }

    @Test func stopWithoutARecordingIsAToolError() async throws {
        let reply = try await call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"stop_recording"}}"#)
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test func rejectsAnUnknownResolutionBeforeRecording() async throws {
        let line = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"start_recording","arguments":{"resolution":"8k","display_id":-1}}}"#
        let result = try #require(try await call(line)["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test func matchesWindowsByTitleBeforeAppName() {
        let windows = [
            SourceWindow(id: 1, app: "Google Chrome", bundleID: "com.google.Chrome", title: "Inbox"),
            SourceWindow(id: 2, app: "Slack", bundleID: "com.tinyspeck.slackmacgap", title: "Chrome tips"),
            SourceWindow(id: 3, app: "Google Chrome", bundleID: "com.google.Chrome", title: "Dashboard"),
        ]
        #expect(RecordingSources.bestWindow(matching: "dashboard", in: windows)?.id == 3)
        #expect(RecordingSources.bestWindow(matching: "chrome", in: windows)?.id == 2)
        #expect(RecordingSources.bestWindow(matching: "Google Chrome", in: windows)?.id == 1)
        #expect(RecordingSources.bestWindow(matching: "com.tinyspeck.slackmacgap", in: windows)?.id == 2)
        #expect(RecordingSources.bestWindow(matching: "Xcode", in: windows) == nil)
    }

    @Test func annotateRejectsAnUnknownKindAndAMissingTarget() async throws {
        let unknown = #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"annotate","arguments":{"kind":"sparkle"}}}"#
        #expect((try await call(unknown)["result"] as? [String: Any])?["isError"] as? Bool == true)
        let missing = #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"annotate","arguments":{"kind":"circle"}}}"#
        #expect((try await call(missing)["result"] as? [String: Any])?["isError"] as? Bool == true)
        let zoom = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"zoom_in","arguments":{"x":1,"y":1}}}"#
        #expect((try await call(zoom)["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func zoomFitsTheTargetKeepsTheAspectAndStaysInside() {
        let base = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let aspect: CGFloat = 1920.0 / 1080.0
        let zoomed = ZoomMath.rect(focus: CGRect(x: 800, y: 500, width: 200, height: 40), base: base, aspect: aspect, scale: nil)
        #expect(abs(zoomed.width / zoomed.height - aspect) < 0.001)
        #expect(zoomed.width == 480)
        #expect(base.contains(zoomed))
        let corner = ZoomMath.rect(focus: CGRect(x: 1900, y: 1060, width: 10, height: 10), base: base, aspect: aspect, scale: 2)
        #expect(corner == CGRect(x: 960, y: 540, width: 960, height: 540))
        #expect(ZoomMath.rect(focus: base, base: base, aspect: aspect, scale: nil) == base)
        let wide = ZoomMath.rect(focus: CGRect(x: 20, y: 700, width: 1880, height: 200), base: base, aspect: aspect, scale: nil)
        #expect(wide.width == 1920 / ZoomMath.minZoom)
        #expect(wide.contains(CGPoint(x: 960, y: 800)))
        #expect(ZoomMath.interpolate(from: base, to: corner, progress: 1) == corner)
        #expect(ZoomMath.interpolate(from: base, to: corner, progress: 0.5).width == 1440)
    }

    @Test func arrowsPointAtTheTargetFromTheScreenCenterSide() {
        let canvas = CGSize(width: 1920, height: 1080)
        let points = ArrowGeometry.points(target: CGRect(x: 40, y: 40, width: 100, height: 40), canvas: canvas)
        #expect(points.end.x > 90 && points.end.y > 60)
        #expect(points.start.x > points.end.x && points.start.y > points.end.y)
        let edge = ArrowGeometry.points(target: CGRect(x: 1880, y: 500, width: 40, height: 40), canvas: canvas)
        #expect(edge.start.x < edge.end.x)
        #expect(edge.start.x <= canvas.width - ArrowGeometry.margin)
    }

    @Test func parsesKeysAndShortcuts() {
        #expect(KeyCombo.parse("return") == KeyCombo(keyCode: 36, flags: []))
        #expect(KeyCombo.parse("Cmd+Shift+N") == KeyCombo(keyCode: 45, flags: [.maskCommand, .maskShift]))
        #expect(KeyCombo.parse("esc")?.keyCode == 53)
        #expect(KeyCombo.parse("hyper+k") == nil)
        #expect(KeyCombo.parse("cmd+") == nil)
    }

    @Test func scoresLabelsExactThenPrefixThenContains() {
        #expect(ElementMatch.score("Screen Record", labels: ["screen record"]) == 3)
        #expect(ElementMatch.score("Start", labels: ["Start Recording"]) == 2)
        #expect(ElementMatch.score("record", labels: ["Start Recording", "Stop"]) == 1)
        #expect(ElementMatch.score("Jira", labels: ["Displays"]) == 0)
        #expect(ElementMatch.roleMatches("AXButton", filter: "button"))
        #expect(!ElementMatch.roleMatches("AXStaticText", filter: "button"))
        #expect(ElementMatch.rolePriority("AXImage") < ElementMatch.rolePriority("AXStaticText"))
    }

    @Test func parsesColorNamesAndHex() {
        #expect(DemoColor.parse(nil) == DemoColor.accent)
        #expect(DemoColor.parse("Blue") == .systemBlue)
        #expect(DemoColor.parse("#00FF00")?.greenComponent == 1)
        #expect(DemoColor.parse("#12") == nil)
    }

    @Test func recordsAWindowAsItsAreaOfTheDisplay() {
        let display = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        #expect(RecordingSources.region(of: CGRect(x: 2154, y: 76, width: 1400, height: 1000), on: display)
            == CGRect(x: 234, y: 76, width: 1400, height: 1000))
        #expect(RecordingSources.region(of: CGRect(x: 3500, y: 900, width: 800, height: 400), on: display)
            == CGRect(x: 1580, y: 900, width: 340, height: 180))
    }

    @Test func prefersTheLargestWindowWhenSeveralMatchEqually() {
        let windows = [
            SourceWindow(id: 1, app: "Clean macOS", bundleID: "click.ngoctruong.CleanMacOS", title: "Clean macOS", area: 160 * 140),
            SourceWindow(id: 2, app: "Clean macOS", bundleID: "click.ngoctruong.CleanMacOS", title: "Clean macOS", area: 1680 * 909),
        ]
        #expect(RecordingSources.bestWindow(matching: "clean macos", in: windows)?.id == 2)
    }

    @Test func timelineCutsPausesOutOfTheVideo() {
        let second = { (value: Double) in CMTime(seconds: value, preferredTimescale: 600) }
        var timeline = RecordingTimeline()
        #expect(timeline.adjusted(second(5)) == second(5))
        timeline.pause(at: second(10))
        #expect(timeline.adjusted(second(12)) == nil)
        #expect(timeline.outputTime(at: second(14)) == second(10))
        timeline.resume(at: second(15))
        #expect(timeline.adjusted(second(9)) == second(9))
        #expect(timeline.adjusted(second(16)) == second(11))
        timeline.pause(at: second(20))
        timeline.resume(at: second(30))
        #expect(timeline.adjusted(second(31)) == second(16))
        #expect(timeline.adjusted(second(25)) == nil)
        #expect(timeline.outputTime(at: second(33)) == second(18))
        timeline.resume(at: second(40))
        #expect(timeline.pauses.count == 2)
    }
}
