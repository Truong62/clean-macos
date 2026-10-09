import Foundation
import Testing
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

struct JiraSummaryTests {
    private func summary(_ overrides: JiraJSON = [:]) -> JiraJSON {
        JiraFixtures.mapper.summary(JiraFixtures.makeIssue(overrides))
    }

    @Test func mapsCoreFieldsAndLastSprint() {
        let row = summary()
        #expect(row["key"] as? String == "FAL-1120")
        #expect(row["status"] as? String == "Doing")
        #expect(row["statusId"] as? String == "10400")
        #expect(row["sprint"] as? String == "Falcon Sprint 7")
        #expect(row["sprintId"] as? Int == 71)
        #expect(row["created"] as? String == "2026-10-08")
        #expect(row["resolved"] is NSNull)
        #expect(row["isDone"] as? Bool == false)
        #expect(row["url"] as? String == "https://space.avada.net/browse/FAL-1120")
    }

    @Test func warnsMissingFalconApp() {
        #expect((summary()["warnings"] as? [String])?.contains("missing_falcon_app") == true)
    }

    @Test func warnsDoneWithoutDevPoint() {
        let row = summary(["status": JiraFixtures.done, "customfield_11203": ["value": "SEO"]])
        #expect(row["warnings"] as? [String] == ["done_without_dev_point"])
    }

    @Test func noWarningsWhenComplete() {
        let row = summary(["status": JiraFixtures.done, "customfield_11203": ["value": "SEO"],
                           "customfield_11204": ["value": "3"]])
        #expect(row["warnings"] as? [String] == [])
        #expect(row["devPoint"] as? String == "3")
        #expect(row["falconApp"] as? String == "SEO")
    }

    @Test func noSprint() {
        let row = summary(["customfield_10101": NSNull()])
        #expect(row["sprint"] is NSNull)
        #expect(row["sprintId"] is NSNull)
    }

    @Test func mapsAssigneesWithLocalAvatar() {
        let user: JiraJSON = ["name": "truongnn", "displayName": "Ngọc Trường", "avatarUrls": [
            "48x48": "https://space.avada.net/secure/useravatar?ownerId=JIRAUSER12206&avatarId=12401"]]
        let row = summary(["customfield_10700": [user]])
        #expect(row["assignees"] as? [[String: String]] == [[ "name": "truongnn", "displayName": "Ngọc Trường", "avatar": "/api/avatar?ownerId=JIRAUSER12206&avatarId=12401"]])
    }

    @Test func parentFromSubtask() {
        let row = summary(["parent": ["key": "FAL-541", "fields": ["summary": "[DEV] Pricing v2"]]])
        #expect(row["parentKey"] as? String == "FAL-541")
    }

    @Test func bugParentFromLinkToNonBug() {
        let links: [JiraJSON] = [
            ["type": ["name": "Relates"], "inwardIssue": ["key": "FAL-900", "fields": [
                "summary": "[BUG] Other", "issuetype": ["name": "Bug"]]]],
            ["type": ["name": "Relates"], "outwardIssue": ["key": "FAL-541", "fields": [
                "summary": "[DEV][Speed] Pricing v2", "issuetype": ["name": "Task"]]]],
        ]
        let row = summary(["summary": "[BUG][Speed] Plan sai", "issuetype": ["name": "Bug"], "issuelinks": links])
        #expect(row["parentKey"] as? String == "FAL-541")
        #expect(row["isBug"] as? Bool == true)
    }

    @Test func taskLinksDoNotMakeParent() {
        let links: [JiraJSON] = [["type": ["name": "Relates"], "outwardIssue": ["key": "FAL-541", "fields": [
            "summary": "[DEV] Pricing v2", "issuetype": ["name": "Task"]]]]]
        #expect(summary(["summary": "[DEV] X", "issuelinks": links])["parentKey"] is NSNull)
    }

    @Test func mapsPointsPerRole() {
        let row = summary(["customfield_11204": ["value": "5"], "customfield_11202": ["value": "2"]])
        let points = row["rolePoints"] as? JiraJSON ?? [:]
        #expect(points["dev"] as? String == "5")
        #expect(points["tester"] as? String == "2")
        #expect(points["ba"] is NSNull)
        #expect(points["designer"] is NSNull)
    }

    @Test func noAssignees() {
        #expect((summary()["assignees"] as? [Any])?.count == 0)
    }

    @Test func noAppOrPointFieldMeansNoWarnings() {
        let mapper = JiraMapper(baseURL: JiraFixtures.baseURL, fields: JiraFieldMap(ids: [.assignees: "assignee"]))
        let row = mapper.summary(JiraFixtures.makeIssue(["status": JiraFixtures.done]))
        #expect(row["warnings"] as? [String] == [])
        #expect(row["falconApp"] is NSNull)
    }

    @Test func standardAssigneeAndCloudAccountId() {
        let mapper = JiraMapper(baseURL: JiraFixtures.baseURL, fields: JiraFieldMap(ids: [.assignees: "assignee"]))
        let user: JiraJSON = ["accountId": "5b10ac", "displayName": "Tony", "avatarUrls": ["48x48": "https://x/a?avatarId=1"]]
        let row = mapper.summary(JiraFixtures.makeIssue(["assignee": user]))
        #expect((row["assignees"] as? [JiraJSON])?.first?["name"] as? String == "5b10ac")
    }

    @Test func cloudSprintObjects() {
        let sprint = JiraMapper.parseLastSprint([["id": 1, "name": "S1"], ["id": 2, "name": "S2"]])
        #expect(sprint.id == 2)
        #expect(sprint.name == "S2")
    }
}

struct JiraKpiTests {
    private let header = ["Month", "Task Name", "Description", "Task Link", "Dev Point", "Tester Point"]

    @Test func mapsJiraKeyToKpiMonth() {
        let rows = [header, ["T9 26", "Task - X", "", "https://space.avada.net/browse/FAL-1044", "5", "2"]]
        #expect(JiraKpi.parseRows(rows, projectKey: "FAL") == ["FAL-1044": JiraKpiEntry(month: "2026-09", devPoint: "5", testerPoint: "2")])
    }

    @Test func keepsLatestMonthAndSkipsRowsWithoutKey() {
        let rows = [
            header,
            ["T10 26", "Task", "", "https://space.avada.net/browse/FAL-7", "3"],
            ["T8 26", "Task", "", "https://space.avada.net/browse/FAL-7", "1"],
            ["T7 26", "Notion task", "", "https://app.notion.com/p/x", "2"],
            ["", "Empty month", "", "https://space.avada.net/browse/FAL-8"],
        ]
        #expect(JiraKpi.parseRows(rows, projectKey: "FAL") == ["FAL-7": JiraKpiEntry(month: "2026-10", devPoint: "3", testerPoint: "")])
    }

    @Test func addsCountedElsewhereMonthWithoutOverridingSheetRows() {
        let sheet = ["FAL-7": JiraKpiEntry(month: "2026-07", devPoint: "3", testerPoint: "")]
        let merged = JiraKpi.addCountedElsewhere(sheet, keys: ["FAL-7", "FAL-114"], month: "2026-06")
        #expect(merged["FAL-7"]?.month == "2026-07")
        #expect(merged["FAL-114"] == JiraKpiEntry(month: "2026-06", devPoint: "", testerPoint: "", source: JiraKpi.countedElsewhereSource))
        #expect(sheet["FAL-114"] == nil)
    }

    @Test func storeRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("jira-kpi.json")
        let store = JiraKpiStore(fileURL: url)
        #expect(store.read() == nil)
        let data = JiraKpiData(syncedAt: "2026-10-09",
                               issues: ["FAL-1": JiraKpiEntry(month: "2026-09", devPoint: "2", testerPoint: "")])
        try store.write(data)
        #expect(store.read() == data)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

struct JiraAvatarParamsTests {
    @Test func keepsOnlyAvatarKeys() throws {
        #expect(try JiraMapper.avatarParams("ownerId=JIRAUSER1&avatarId=12401&size=small&next=/x") == ["ownerId": "JIRAUSER1", "avatarId": "12401", "size": "small"])
    }

    @Test func rejectsMissingAvatarId() {
        #expect(throws: (any Error).self) { try JiraMapper.avatarParams("ownerId=JIRAUSER1") }
    }

    @Test func rejectsUnsafeValue() {
        #expect(throws: (any Error).self) { try JiraMapper.avatarParams("avatarId=1&ownerId=../admin") }
    }
}

struct JiraDetailTests {
    @Test func absolutizesJiraLinksAndMapsExtras() {
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
        #expect(html.contains(#"src="https://space.avada.net/secure/attachment/1/a.png""#))
        #expect(html.contains(#"href="https://space.avada.net/browse/FAL-1""#))
        #expect(detail["descriptionRaw"] as? String == "h1. Raw")
        let comment = (detail["comments"] as? [JiraJSON])?.first ?? [:]
        #expect(comment["author"] as? String == "Tony")
        #expect(comment["created"] as? String == "2026-10-08 10:00")
        #expect((comment["bodyHtml"] as? String ?? "").contains("https://space.avada.net/browse/FAL-2"))
        #expect(detail["transitions"] as? [[String: String]] == [["id": "61", "name": "Waiting To Test", "toId": "10401"]])
        #expect((detail["options"] as? JiraJSON)?["falconApp"] as? [String] == ["SEO", "Team"])
        #expect(detail["mergeRequest"] as? String == "https://git/mr/1")
    }
}

struct JiraUpdateFieldsTests {
    private let mapper = JiraFixtures.mapper

    private func assertJSONEqual(_ actual: JiraJSON, _ expected: JiraJSON, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(NSDictionary(dictionary: actual).isEqual(to: expected), "\(actual) != \(expected)", sourceLocation: sourceLocation)
    }

    @Test func mapsEachField() throws {
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

    @Test func emptyValuesClearField() throws {
        let fields = try mapper.updateFields(["falconApp": NSNull(), "devPoint": "", "dueDate": "", "sprintId": NSNull()])
        assertJSONEqual(fields, ["customfield_11203": NSNull(), "customfield_11204": NSNull(),
                                 "duedate": NSNull(), "customfield_10101": NSNull()])
    }

    @Test func rejectsUnknownField() {
        #expect(throws: (any Error).self) { try mapper.updateFields(["reporter": "x"]) }
    }

    @Test func rejectsEmptySummary() {
        #expect(throws: (any Error).self) { try mapper.updateFields(["summary": "  "]) }
    }

    @Test func rejectsEmptyChanges() {
        #expect(throws: (any Error).self) { try mapper.updateFields([:]) }
    }

    @Test func rejectsUnconfiguredField() {
        let bare = JiraMapper(baseURL: JiraFixtures.baseURL, fields: JiraFieldMap(ids: [.assignees: "assignee"]))
        #expect(throws: (any Error).self) { try bare.updateFields(["falconApp": "SEO"]) }
    }
}

struct JiraPickTransitionTests {
    private let transitions: [JiraJSON] = [
        ["id": "41", "name": "Doing", "to": ["id": "10400"]],
        ["id": "61", "name": "Waiting To Test", "to": ["id": "10401"]],
        ["id": "251", "name": "done", "to": ["id": "10001"]],
    ]

    @Test func picksTransitionIntoColumn() {
        #expect(JiraMapper.pickTransition(transitions, statusIds: ["10001", "10407"]) == "251")
    }

    @Test func noneWhenColumnUnreachable() {
        #expect(JiraMapper.pickTransition(transitions, statusIds: ["10102"]) == nil)
    }
}

struct JiraEventsTests {
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

    @Test func notifiesNewAssignmentOnce() {
        let (events, next) = detect([issue()], state())
        #expect(events.map(\.kind) == [.assigned])
        #expect(events.first?.message == "You were added to: Dev Zone")
        #expect(detect([issue()], next).0 == [])
    }

    @Test func forgetsRemovedAssignment() {
        let (_, next) = detect([issue(assignees: ["tony"])], state(known: ["FAL-1"]))
        #expect(!next.knownAssigned.contains("FAL-1"))
    }

    @Test func notifiesCommentOnMyTaskOnce() {
        let mine = issue(comments: [comment()])
        let (events, next) = detect([mine], state(known: ["FAL-1"]))
        #expect(events.map(\.kind) == [.comment])
        #expect(events.first?.title == "FAL-1 · Dev Zone")
        #expect(events.first?.message == "Tony: ok")
        #expect(detect([mine], next).0 == [])
    }

    @Test func notifiesMentionOnOtherTask() {
        let other = issue(assignees: ["tony"], comments: [comment(body: "nhờ [~truongnn] xem")])
        #expect(detect([other], state()).0.map(\.kind) == [.mention])
    }

    @Test func notifiesCloudMention() {
        let other = issue(assignees: ["tony"], comments: [comment(body: "hi [~accountid:5b10ac]")])
        #expect(detect([other], state(), me: "5b10ac").0.map(\.kind) == [.mention])
    }

    @Test func ignoresOwnOldAndUnrelatedComments() {
        let comments = [comment("1", author: "truongnn"), comment("2", created: "2026-10-08T09:00:00.000+0700")]
        let (mine, _) = detect([issue(comments: comments)], state(known: ["FAL-1"]))
        let (other, _) = detect([issue(assignees: ["tony"], comments: [comment("3")])], state())
        #expect(mine + other == [])
    }
}
