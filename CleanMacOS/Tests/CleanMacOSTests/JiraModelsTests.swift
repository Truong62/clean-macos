import XCTest
@testable import CleanMacOS

enum JiraFixtures {
    static let baseURL = "https://space.avada.net"
    static let sprint7 = "com.atlassian.greenhopper.service.sprint.Sprint@1a[activatedDate=2026-10-05T14:02:57.207+07:00,goal=<null>,id=71,name=Falcon Sprint 7,rapidViewId=10028,state=ACTIVE]"
    static let sprint6 = "com.atlassian.greenhopper.service.sprint.Sprint@1b[id=70,rapidViewId=10030,state=CLOSED,name=Falcon Sprint 6,startDate=2026-09-21]"
    static let avadaFields = JiraFieldMap(ids: [
        .sprint: "customfield_10101", .assignees: "customfield_10700", .app: "customfield_11203",
        .devPoint: "customfield_11204", .testerPoint: "customfield_11202", .baPoint: "customfield_10701",
        .designerPoint: "customfield_10702", .mergeRequest: "customfield_10800", .reviewers: "customfield_10900",
    ], names: [.app: "Falcon App", .devPoint: "Dev Point", .testerPoint: "Tester Point"])
    static let mapper = JiraMapper(baseURL: baseURL, fields: avadaFields)

    static func makeIssue(_ overrides: JiraJSON = [:]) -> JiraJSON {
        var fields: JiraJSON = [
            "summary": "Dev Zone",
            "status": ["id": "10400", "name": "Doing", "statusCategory": ["key": "indeterminate"]],
            "issuetype": ["name": "Task"],
            "priority": ["name": "Medium"],
            "created": "2026-10-08T09:00:00.000+0700",
            "updated": "2026-10-08T10:00:00.000+0700",
            "resolutiondate": NSNull(),
            "duedate": NSNull(),
            "customfield_11203": NSNull(),
            "customfield_11204": NSNull(),
            "customfield_10101": [sprint6, sprint7],
            "customfield_10800": NSNull(),
            "customfield_10900": NSNull(),
            "customfield_10700": NSNull(),
            "description": "h1. Raw",
        ]
        fields.merge(overrides) { _, new in new }
        return ["key": "FAL-1120", "fields": fields]
    }

    static let done: JiraJSON = ["id": "10001", "name": "Done", "statusCategory": ["key": "done"]]
}

final class JiraSummaryTests: XCTestCase {
    private func summary(_ overrides: JiraJSON = [:]) -> JiraJSON {
        JiraFixtures.mapper.summary(JiraFixtures.makeIssue(overrides))
    }

    func testMapsCoreFieldsAndLastSprint() {
        let row = summary()
        XCTAssertEqual(row["key"] as? String, "FAL-1120")
        XCTAssertEqual(row["status"] as? String, "Doing")
        XCTAssertEqual(row["statusId"] as? String, "10400")
        XCTAssertEqual(row["sprint"] as? String, "Falcon Sprint 7")
        XCTAssertEqual(row["sprintId"] as? Int, 71)
        XCTAssertEqual(row["created"] as? String, "2026-10-08")
        XCTAssertTrue(row["resolved"] is NSNull)
        XCTAssertEqual(row["isDone"] as? Bool, false)
        XCTAssertEqual(row["url"] as? String, "https://space.avada.net/browse/FAL-1120")
    }

    func testWarnsMissingFalconApp() {
        XCTAssertTrue((summary()["warnings"] as? [String])?.contains("missing_falcon_app") == true)
    }

    func testWarnsDoneWithoutDevPoint() {
        let row = summary(["status": JiraFixtures.done, "customfield_11203": ["value": "SEO"]])
        XCTAssertEqual(row["warnings"] as? [String], ["done_without_dev_point"])
    }

    func testNoWarningsWhenComplete() {
        let row = summary(["status": JiraFixtures.done, "customfield_11203": ["value": "SEO"],
                           "customfield_11204": ["value": "3"]])
        XCTAssertEqual(row["warnings"] as? [String], [])
        XCTAssertEqual(row["devPoint"] as? String, "3")
        XCTAssertEqual(row["falconApp"] as? String, "SEO")
    }

    func testNoSprint() {
        let row = summary(["customfield_10101": NSNull()])
        XCTAssertTrue(row["sprint"] is NSNull)
        XCTAssertTrue(row["sprintId"] is NSNull)
    }

    func testMapsAssigneesWithLocalAvatar() {
        let user: JiraJSON = ["name": "truongnn", "displayName": "Ngọc Trường", "avatarUrls": [
            "48x48": "https://space.avada.net/secure/useravatar?ownerId=JIRAUSER12206&avatarId=12401"]]
        let row = summary(["customfield_10700": [user]])
        XCTAssertEqual(row["assignees"] as? [[String: String]], [[
            "name": "truongnn", "displayName": "Ngọc Trường",
            "avatar": "/api/avatar?ownerId=JIRAUSER12206&avatarId=12401"]])
    }

    func testParentFromSubtask() {
        let row = summary(["parent": ["key": "FAL-541", "fields": ["summary": "[DEV] Pricing v2"]]])
        XCTAssertEqual(row["parentKey"] as? String, "FAL-541")
    }

    func testBugParentFromLinkToNonBug() {
        let links: [JiraJSON] = [
            ["type": ["name": "Relates"], "inwardIssue": ["key": "FAL-900", "fields": [
                "summary": "[BUG] Other", "issuetype": ["name": "Bug"]]]],
            ["type": ["name": "Relates"], "outwardIssue": ["key": "FAL-541", "fields": [
                "summary": "[DEV][Speed] Pricing v2", "issuetype": ["name": "Task"]]]],
        ]
        let row = summary(["summary": "[BUG][Speed] Plan sai", "issuetype": ["name": "Bug"], "issuelinks": links])
        XCTAssertEqual(row["parentKey"] as? String, "FAL-541")
        XCTAssertEqual(row["isBug"] as? Bool, true)
    }

    func testTaskLinksDoNotMakeParent() {
        let links: [JiraJSON] = [["type": ["name": "Relates"], "outwardIssue": ["key": "FAL-541", "fields": [
            "summary": "[DEV] Pricing v2", "issuetype": ["name": "Task"]]]]]
        XCTAssertTrue(summary(["summary": "[DEV] X", "issuelinks": links])["parentKey"] is NSNull)
    }

    func testMapsPointsPerRole() {
        let row = summary(["customfield_11204": ["value": "5"], "customfield_11202": ["value": "2"]])
        let points = row["rolePoints"] as? JiraJSON ?? [:]
        XCTAssertEqual(points["dev"] as? String, "5")
        XCTAssertEqual(points["tester"] as? String, "2")
        XCTAssertTrue(points["ba"] is NSNull)
        XCTAssertTrue(points["designer"] is NSNull)
    }

    func testNoAssignees() {
        XCTAssertEqual((summary()["assignees"] as? [Any])?.count, 0)
    }

    func testNoAppOrPointFieldMeansNoWarnings() {
        let mapper = JiraMapper(baseURL: JiraFixtures.baseURL, fields: JiraFieldMap(ids: [.assignees: "assignee"]))
        let row = mapper.summary(JiraFixtures.makeIssue(["status": JiraFixtures.done]))
        XCTAssertEqual(row["warnings"] as? [String], [])
        XCTAssertTrue(row["falconApp"] is NSNull)
    }

    func testStandardAssigneeAndCloudAccountId() {
        let mapper = JiraMapper(baseURL: JiraFixtures.baseURL, fields: JiraFieldMap(ids: [.assignees: "assignee"]))
        let user: JiraJSON = ["accountId": "5b10ac", "displayName": "Tony", "avatarUrls": ["48x48": "https://x/a?avatarId=1"]]
        let row = mapper.summary(JiraFixtures.makeIssue(["assignee": user]))
        XCTAssertEqual((row["assignees"] as? [JiraJSON])?.first?["name"] as? String, "5b10ac")
    }

    func testCloudSprintObjects() {
        let sprint = JiraMapper.parseLastSprint([["id": 1, "name": "S1"], ["id": 2, "name": "S2"]])
        XCTAssertEqual(sprint.id, 2)
        XCTAssertEqual(sprint.name, "S2")
    }
}

final class JiraKpiTests: XCTestCase {
    private let header = ["Month", "Task Name", "Description", "Task Link", "Dev Point", "Tester Point"]

    func testMapsJiraKeyToKpiMonth() {
        let rows = [header, ["T9 26", "Task - X", "", "https://space.avada.net/browse/FAL-1044", "5", "2"]]
        XCTAssertEqual(JiraKpi.parseRows(rows, projectKey: "FAL"),
                       ["FAL-1044": JiraKpiEntry(month: "2026-09", devPoint: "5", testerPoint: "2")])
    }

    func testKeepsLatestMonthAndSkipsRowsWithoutKey() {
        let rows = [
            header,
            ["T10 26", "Task", "", "https://space.avada.net/browse/FAL-7", "3"],
            ["T8 26", "Task", "", "https://space.avada.net/browse/FAL-7", "1"],
            ["T7 26", "Notion task", "", "https://app.notion.com/p/x", "2"],
            ["", "Empty month", "", "https://space.avada.net/browse/FAL-8"],
        ]
        XCTAssertEqual(JiraKpi.parseRows(rows, projectKey: "FAL"),
                       ["FAL-7": JiraKpiEntry(month: "2026-10", devPoint: "3", testerPoint: "")])
    }

    func testAddsCountedElsewhereMonthWithoutOverridingSheetRows() {
        let sheet = ["FAL-7": JiraKpiEntry(month: "2026-07", devPoint: "3", testerPoint: "")]
        let merged = JiraKpi.addCountedElsewhere(sheet, keys: ["FAL-7", "FAL-114"], month: "2026-06")
        XCTAssertEqual(merged["FAL-7"]?.month, "2026-07")
        XCTAssertEqual(merged["FAL-114"], JiraKpiEntry(month: "2026-06", devPoint: "", testerPoint: "",
                                                       source: JiraKpi.countedElsewhereSource))
        XCTAssertNil(sheet["FAL-114"])
    }

    func testStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("jira-kpi.json")
        let store = JiraKpiStore(fileURL: url)
        XCTAssertNil(store.read())
        let data = JiraKpiData(syncedAt: "2026-10-09",
                               issues: ["FAL-1": JiraKpiEntry(month: "2026-09", devPoint: "2", testerPoint: "")])
        try store.write(data)
        XCTAssertEqual(store.read(), data)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

final class JiraAvatarParamsTests: XCTestCase {
    func testKeepsOnlyAvatarKeys() throws {
        XCTAssertEqual(try JiraMapper.avatarParams("ownerId=JIRAUSER1&avatarId=12401&size=small&next=/x"),
                       ["ownerId": "JIRAUSER1", "avatarId": "12401", "size": "small"])
    }

    func testRejectsMissingAvatarId() {
        XCTAssertThrowsError(try JiraMapper.avatarParams("ownerId=JIRAUSER1"))
    }

    func testRejectsUnsafeValue() {
        XCTAssertThrowsError(try JiraMapper.avatarParams("avatarId=1&ownerId=../admin"))
    }
}

final class JiraDetailTests: XCTestCase {
    func testAbsolutizesJiraLinksAndMapsExtras() {
        var issue = JiraFixtures.makeIssue(["customfield_10800": "https://git/mr/1"])
        issue["renderedFields"] = [
            "description": #"<img src="/secure/attachment/1/a.png"><a href="/browse/FAL-1">x</a>"#,
            "comment": ["comments": [["id": "9", "body": #"<a href="/browse/FAL-2">y</a>"#,
                                      "author": ["displayName": "Tony"], "created": "2026-10-08T10:00:00.000+0700"]]],
        ]
        issue["transitions"] = [["id": "61", "name": "Waiting To Test", "to": ["id": "10401", "name": "Waiting To Test"]]]
        issue["editmeta"] = ["fields": ["customfield_11203": ["allowedValues": [["value": "SEO"], ["value": "Team"]]]]]
        let detail = JiraFixtures.mapper.detail(issue)
        let html = detail["descriptionHtml"] as? String ?? ""
        XCTAssertTrue(html.contains(#"src="https://space.avada.net/secure/attachment/1/a.png""#))
        XCTAssertTrue(html.contains(#"href="https://space.avada.net/browse/FAL-1""#))
        XCTAssertEqual(detail["descriptionRaw"] as? String, "h1. Raw")
        let comment = (detail["comments"] as? [JiraJSON])?.first ?? [:]
        XCTAssertEqual(comment["author"] as? String, "Tony")
        XCTAssertEqual(comment["created"] as? String, "2026-10-08 10:00")
        XCTAssertTrue((comment["bodyHtml"] as? String ?? "").contains("https://space.avada.net/browse/FAL-2"))
        XCTAssertEqual(detail["transitions"] as? [[String: String]], [["id": "61", "name": "Waiting To Test", "toId": "10401"]])
        XCTAssertEqual((detail["options"] as? JiraJSON)?["falconApp"] as? [String], ["SEO", "Team"])
        XCTAssertEqual(detail["mergeRequest"] as? String, "https://git/mr/1")
    }
}

final class JiraUpdateFieldsTests: XCTestCase {
    private let mapper = JiraFixtures.mapper

    private func assertJSONEqual(_ actual: JiraJSON, _ expected: JiraJSON, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected), "\(actual) != \(expected)", file: file, line: line)
    }

    func testMapsEachField() throws {
        let fields = try mapper.updateFields([
            "summary": " New title ", "description": "body", "falconApp": "Team", "devPoint": "3",
            "priority": "High", "dueDate": "2026-10-20", "sprintId": 71, "mergeRequest": "https://x",
        ])
        assertJSONEqual(fields, [
            "summary": "New title", "description": "body",
            "customfield_11203": ["value": "Team"], "customfield_11204": ["value": "3"],
            "priority": ["name": "High"], "duedate": "2026-10-20",
            "customfield_10101": 71, "customfield_10800": "https://x",
        ])
    }

    func testEmptyValuesClearField() throws {
        let fields = try mapper.updateFields(["falconApp": NSNull(), "devPoint": "", "dueDate": "", "sprintId": NSNull()])
        assertJSONEqual(fields, ["customfield_11203": NSNull(), "customfield_11204": NSNull(),
                                 "duedate": NSNull(), "customfield_10101": NSNull()])
    }

    func testRejectsUnknownField() {
        XCTAssertThrowsError(try mapper.updateFields(["reporter": "x"]))
    }

    func testRejectsEmptySummary() {
        XCTAssertThrowsError(try mapper.updateFields(["summary": "  "]))
    }

    func testRejectsEmptyChanges() {
        XCTAssertThrowsError(try mapper.updateFields([:]))
    }

    func testRejectsUnconfiguredField() {
        let bare = JiraMapper(baseURL: JiraFixtures.baseURL, fields: JiraFieldMap(ids: [.assignees: "assignee"]))
        XCTAssertThrowsError(try bare.updateFields(["falconApp": "SEO"]))
    }
}

final class JiraPickTransitionTests: XCTestCase {
    private let transitions: [JiraJSON] = [
        ["id": "41", "name": "Doing", "to": ["id": "10400"]],
        ["id": "61", "name": "Waiting To Test", "to": ["id": "10401"]],
        ["id": "251", "name": "done", "to": ["id": "10001"]],
    ]

    func testPicksTransitionIntoColumn() {
        XCTAssertEqual(JiraMapper.pickTransition(transitions, statusIds: ["10001", "10407"]), "251")
    }

    func testNoneWhenColumnUnreachable() {
        XCTAssertNil(JiraMapper.pickTransition(transitions, statusIds: ["10102"]))
    }
}

final class JiraEventsTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-10-08T10:00:00+07:00")!
    private let assigneesField = "customfield_10700"

    private func issue(key: String = "FAL-1", assignees: [String] = ["truongnn"], comments: [JiraJSON] = []) -> JiraJSON {
        ["key": key, "fields": [
            "summary": "Dev Zone",
            assigneesField: assignees.map { ["name": $0] },
            "comment": ["comments": comments],
        ] as JiraJSON]
    }

    private func comment(_ id: String = "9", author: String = "tony",
                         created: String = "2026-10-08T10:05:00.000+0700", body: String = "ok") -> JiraJSON {
        ["id": id, "author": ["name": author, "displayName": author.capitalized], "created": created, "body": body]
    }

    private func state(known: Set<String> = [], seen: Set<String> = []) -> JiraWatchState {
        JiraWatchState(knownAssigned: known, seenComments: seen, since: start)
    }

    private func detect(_ issues: [JiraJSON], _ state: JiraWatchState, me: String = "truongnn") -> ([JiraEvent], JiraWatchState) {
        let result = JiraEvents.detect(issues, me: me, assigneesField: assigneesField, state: state)
        return (result.events, result.state)
    }

    func testNotifiesNewAssignmentOnce() {
        let (events, next) = detect([issue()], state())
        XCTAssertEqual(events.map(\.kind), [.assigned])
        XCTAssertEqual(events.first?.message, "You were added to: Dev Zone")
        XCTAssertEqual(detect([issue()], next).0, [])
    }

    func testForgetsRemovedAssignment() {
        let (_, next) = detect([issue(assignees: ["tony"])], state(known: ["FAL-1"]))
        XCTAssertFalse(next.knownAssigned.contains("FAL-1"))
    }

    func testNotifiesCommentOnMyTaskOnce() {
        let mine = issue(comments: [comment()])
        let (events, next) = detect([mine], state(known: ["FAL-1"]))
        XCTAssertEqual(events.map(\.kind), [.comment])
        XCTAssertEqual(events.first?.title, "FAL-1 · Dev Zone")
        XCTAssertEqual(events.first?.message, "Tony: ok")
        XCTAssertEqual(detect([mine], next).0, [])
    }

    func testNotifiesMentionOnOtherTask() {
        let other = issue(assignees: ["tony"], comments: [comment(body: "nhờ [~truongnn] xem")])
        XCTAssertEqual(detect([other], state()).0.map(\.kind), [.mention])
    }

    func testNotifiesCloudMention() {
        let other = issue(assignees: ["tony"], comments: [comment(body: "hi [~accountid:5b10ac]")])
        XCTAssertEqual(detect([other], state(), me: "5b10ac").0.map(\.kind), [.mention])
    }

    func testIgnoresOwnOldAndUnrelatedComments() {
        let comments = [comment("1", author: "truongnn"), comment("2", created: "2026-10-08T09:00:00.000+0700")]
        let (mine, _) = detect([issue(comments: comments)], state(known: ["FAL-1"]))
        let (other, _) = detect([issue(assignees: ["tony"], comments: [comment("3")])], state())
        XCTAssertEqual(mine + other, [])
    }
}
