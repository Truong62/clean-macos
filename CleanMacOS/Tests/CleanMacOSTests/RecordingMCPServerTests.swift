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

    @Test func listsTheThreeRecordingTools() async throws {
        let reply = try await call(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
        let tools = try #require((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String } == ["list_sources", "start_recording", "stop_recording"])
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

    @Test func prefersTheLargestWindowWhenSeveralMatchEqually() {
        let windows = [
            SourceWindow(id: 1, app: "Clean macOS", bundleID: "click.ngoctruong.CleanMacOS", title: "Clean macOS", area: 160 * 140),
            SourceWindow(id: 2, app: "Clean macOS", bundleID: "click.ngoctruong.CleanMacOS", title: "Clean macOS", area: 1680 * 909),
        ]
        #expect(RecordingSources.bestWindow(matching: "clean macos", in: windows)?.id == 2)
    }
}
