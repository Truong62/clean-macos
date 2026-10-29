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
        #expect(names.count == 18)
        #expect(names.contains("navigate") && names.contains("review_recording") && names.contains("sign_in"))
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

    @Test func readsDevToolsPortAndBrowserProcessArguments() {
        #expect(HeadlessBrowserFiles.port(fromActivePortFile: "53122\n/devtools/browser/abc\n") == 53122)
        #expect(HeadlessBrowserFiles.port(fromActivePortFile: "") == nil)
        #expect(HeadlessBrowserFiles.processID(fromSingletonLock: "Mac-mini.local-4242") == 4242)
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/Apps/Chrome".utf8) + [0, 0, 0]
        bytes += Array("Chrome".utf8) + [0] + Array("--headless=new".utf8) + [0] + Array("PATH=/bin".utf8) + [0]
        #expect(HeadlessBrowserFiles.arguments(fromProcessArgs: bytes) == ["Chrome", "--headless=new"])
        #expect(HeadlessBrowserFiles.arguments(fromProcessArgs: [1, 0]).isEmpty)
    }

    @Test func composesFramesWithTheZoomCrop() {
        let output = CGSize(width: 1920, height: 1080)
        let full = FrameComposer.transform(imageSize: output, crop: CGRect(origin: .zero, size: output), output: output)
        #expect(CGPoint(x: 100, y: 200).applying(full) == CGPoint(x: 100, y: 200))
        let crop = CGRect(x: 960, y: 0, width: 960, height: 540)
        let zoomed = FrameComposer.transform(imageSize: output, crop: crop, output: output)
        #expect(CGPoint(x: 960, y: 540).applying(zoomed) == CGPoint(x: 0, y: 0))
        #expect(CGPoint(x: 1920, y: 1080).applying(zoomed) == CGPoint(x: 1920, y: 1080))
        let half = FrameComposer.transform(imageSize: CGSize(width: 960, height: 540), crop: CGRect(origin: .zero, size: output), output: output)
        #expect(CGPoint(x: 960, y: 540).applying(half) == CGPoint(x: 1920, y: 1080))
    }

    @Test func zoomTrackEasesFromWhereItIsTowardsTheTarget() {
        let base = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let target = CGRect(x: 960, y: 540, width: 960, height: 540)
        var track = ZoomTrack(base: base)
        #expect(track.rect(at: 5) == base)
        track.move(to: target, at: 10, duration: 1)
        #expect(track.rect(at: 10) == base)
        #expect(track.rect(at: 10.5).width == 1440)
        #expect(track.rect(at: 11) == target)
        track.move(to: base, at: 10.5, duration: 1)
        #expect(track.rect(at: 10.5).width == 1440)
        #expect(track.rect(at: 12) == base)
    }

    @Test func mapsKeysForTheHiddenBrowser() {
        #expect(WebKey.parse("return") == WebKey(key: "Enter", code: "Enter", keyCode: 13, text: "\r", modifiers: 0))
        #expect(WebKey.parse("shift+tab") == WebKey(key: "Tab", code: "Tab", keyCode: 9, text: nil, modifiers: 8))
        #expect(WebKey.parse("cmd+a") == WebKey(key: "a", code: "KeyA", keyCode: 65, text: nil, modifiers: 4))
        #expect(WebKey.parse("shift+k")?.text == "K")
        #expect(WebKey.parse("7") == WebKey(key: "7", code: "Digit7", keyCode: 55, text: "7", modifiers: 0))
        #expect(WebKey.parse("hyper+a") == nil)
        #expect(WebKey.parse("f13") == nil)
    }

    @Test func encodesValuesForPageScripts() {
        #expect(JSValue.encode("say \"hi\"\n</script>") == #""say \"hi\"\n</script>""#)
        #expect(JSValue.encode(nil) == "null")
        #expect(JSValue.encode(NSNull()) == "null")
        #expect(JSValue.encode(3) == "3")
        #expect(DemoColor.hex(DemoColor.parse("#12AB34")!) == "#12AB34")
        #expect(BrowserURL.isAllowed("http://localhost:3000/app"))
        #expect(BrowserURL.isAllowed("file:///tmp/demo.html"))
        #expect(!BrowserURL.isAllowed("javascript:alert(1)"))
        #expect(!BrowserURL.isAllowed("localhost:3000"))
    }

    @Test func cleansCustomVideoNames() {
        #expect(ScreenRecording.customFileName("task-board-demo") == "task-board-demo.mp4")
        #expect(ScreenRecording.customFileName("Demo.MP4") == "Demo.mp4")
        #expect(ScreenRecording.customFileName("../../etc/passwd") == "-..-etc-passwd.mp4")
        #expect(ScreenRecording.customFileName("a:b") == "a-b.mp4")
        #expect(ScreenRecording.customFileName("  ...  ") == nil)
    }

    @Test func renamesWithoutOverwriting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("one.mp4")
        let second = folder.appendingPathComponent("two.mp4")
        try Data([1]).write(to: first)
        try Data([2]).write(to: second)
        #expect(try AgentRecordingSession.rename(first, to: "demo").lastPathComponent == "demo.mp4")
        #expect(try AgentRecordingSession.rename(second, to: "demo").lastPathComponent == "demo 2.mp4")
        #expect(try Data(contentsOf: folder.appendingPathComponent("demo.mp4")) == Data([1]))
    }

    @Test func countsOpenPagesOfTheSignInBrowser() {
        let targets = #"[{"type":"page","url":"https://a"},{"type":"service_worker"},{"type":"page","url":"chrome://newtab/"}]"#
        #expect(SignInBrowser.pageCount(fromTargets: Data(targets.utf8)) == 2)
        #expect(SignInBrowser.pageCount(fromTargets: Data("[]".utf8)) == 0)
        #expect(SignInBrowser.pageCount(fromTargets: Data("oops".utf8)) == nil)
    }

    @Test func signInRefusesWhileAHiddenRecordingCouldUseTheProfile() async throws {
        let reply = try await call(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"sign_in","arguments":{"url":"ftp://x"}}}"#)
        #expect((reply["result"] as? [String: Any])?["isError"] as? Bool == true)
        #expect(Annotation.Kind(rawValue: "blur") == .blur)
    }
}
