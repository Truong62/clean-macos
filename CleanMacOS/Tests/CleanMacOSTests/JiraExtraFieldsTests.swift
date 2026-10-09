import Foundation
import Testing
@testable import CleanMacOS

struct JiraExtraFieldsTests {
    private func meta(_ name: String, _ schema: JiraJSON, allowed: [String] = []) -> JiraJSON {
        ["name": name, "schema": schema, "allowedValues": allowed.map { ["value": $0] }]
    }

    private var issue: JiraJSON {
        var issue = JiraFixtures.makeIssue([
            "reporter": ["name": "tony", "displayName": "Tony", "avatarUrls": ["48x48": "https://x/secure/useravatar?avatarId=2"]],
            "customfield_11200": "https://staging.example",
            "customfield_10701": ["value": "2"],
            "customfield_11300": "2026-10-01",
            "customfield_12000": 4.5,
            "customfield_12100": ["x"],
        ])
        issue["editmeta"] = ["fields": [
            "summary": meta("Summary", ["type": "string"]),
            "customfield_11203": meta("Falcon App", ["type": "option"], allowed: ["SEO"]),
            "customfield_11204": meta("Dev Point", ["type": "option"], allowed: ["1", "2"]),
            "customfield_10700": meta("Assignees", ["type": "array", "items": "user"]),
            "customfield_11200": meta("Staging", ["type": "string", "custom": "com.atlassian.jira.plugin.system.customfieldtypes:url"]),
            "customfield_10701": meta("BA Point", ["type": "option"], allowed: ["1", "2", "3"]),
            "customfield_11300": meta("KPI Month", ["type": "date"]),
            "customfield_12000": meta("Estimate", ["type": "number"]),
            "customfield_12100": meta("Labels-ish", ["type": "array", "items": "string"]),
        ]]
        return issue
    }

    @Test func detailListsUnhandledEditableFieldsByName() {
        let extras = JiraFixtures.mapper.detail(issue)["extraFields"] as? [JiraJSON] ?? []
        #expect(extras.map { $0["name"] as? String } == ["BA Point", "Estimate", "KPI Month", "Staging"])
        #expect(extras.map { $0["kind"] as? String } == ["option", "number", "date", "url"])
        #expect(extras[0]["value"] as? String == "2")
        #expect(extras[0]["options"] as? [String] == ["1", "2", "3"])
        #expect(extras[1]["value"] as? Double == 4.5)
        #expect(extras[3]["value"] as? String == "https://staging.example")
    }

    @Test func detailIncludesReporter() {
        let reporter = JiraFixtures.mapper.detail(issue)["reporter"] as? JiraJSON
        #expect(reporter?["displayName"] as? String == "Tony")
    }

    @Test func rawUpdatePassesCustomFieldsThrough() throws {
        let update = try JiraFixtures.mapper.updateFields(["raw": ["customfield_10701": ["value": "3"], "customfield_11200": NSNull()]])
        #expect(NSDictionary(dictionary: update).isEqual(to: ["customfield_10701": ["value": "3"], "customfield_11200": NSNull()]))
    }

    @Test func rawUpdateRejectsSystemFields() {
        #expect(throws: (any Error).self) { try JiraFixtures.mapper.updateFields(["raw": ["reporter": ["name": "x"]]]) }
    }

    @Test func pointsFollowTheRoleField() throws {
        var tester = JiraFixtures.mapper
        tester.pointField = .testerPoint
        let summary = tester.summary(JiraFixtures.makeIssue(["customfield_11202": ["value": "5"], "customfield_11204": ["value": "1"]]))
        #expect(summary["devPoint"] as? String == "5")
        let update = try tester.updateFields(["devPoint": "3"])
        #expect(NSDictionary(dictionary: update).isEqual(to: ["customfield_11202": ["value": "3"]]))
    }
}
