import Foundation
import Testing
@testable import CleanMacOS

struct JiraLiveRefreshTests {
    private func issue(_ key: String, _ updated: String) -> JiraJSON {
        ["key": key, "fields": ["updated": updated]]
    }

    @Test func reportsOnlyIssuesWhoseUpdatedTimeMoved() {
        let first = JiraChanges.changedKeys([issue("FAL-1", "t1"), issue("FAL-2", "t1")], seen: [:])
        #expect(first.keys == ["FAL-1", "FAL-2"])
        let second = JiraChanges.changedKeys([issue("FAL-1", "t1"), issue("FAL-2", "t2"), issue("SB-3", "t1")], seen: first.seen)
        #expect(second.keys == ["FAL-2", "SB-3"])
        #expect(second.seen == ["FAL-1": "t1", "FAL-2": "t2", "SB-3": "t1"])
    }

    @Test func issueLeavingTheWindowIsReportedAgainWhenItChanges() {
        let first = JiraChanges.changedKeys([issue("FAL-1", "t1")], seen: [:])
        let gone = JiraChanges.changedKeys([], seen: first.seen)
        #expect(gone.keys.isEmpty)
        #expect(JiraChanges.changedKeys([issue("FAL-1", "t5")], seen: gone.seen).keys == ["FAL-1"])
    }

    @Test func remoteUpdateScriptPassesKeysAsJSON() {
        #expect(JiraWebView.remoteUpdateScript(["FAL-1", "SB-2"]) == #"void window.jiraRemoteUpdate?.(["FAL-1","SB-2"])"#)
    }
}
