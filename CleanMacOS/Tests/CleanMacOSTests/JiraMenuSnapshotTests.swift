import Foundation
import Testing
@testable import CleanMacOS

struct JiraMenuSnapshotTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }()
    private let now = ISO8601DateFormatter().date(from: "2026-10-09T03:00:00Z")!
    private let meta: JiraJSON = [
        "me": ["name": "truongnn"], "role": "dev",
        "sprints": [["name": "Falcon Sprint 42", "state": "active", "endDate": "2026-10-12T10:00:00.000Z"],
                    ["name": "Falcon Sprint 43", "state": "future"]],
    ]

    private func issue(_ key: String, status: String = "Doing", updated: String = "2026-10-05T10:00:00.000+0700",
                       isDone: Bool = false, assignee: String = "truongnn", points: Any = "3") -> JiraJSON {
        ["key": key, "summary": "[SEO] [Bug] Fix sitemap", "status": status, "updated": updated, "isDone": isDone,
         "falconApp": "SEO", "isBug": false, "rolePoints": ["dev": points], "assignees": [["name": assignee]]]
    }

    private func make(_ issues: [JiraJSON], kpi: [String: JiraKpiEntry] = [:]) -> JiraMenuSnapshot {
        JiraMenuSnapshot.make(issues: issues, meta: meta, kpi: kpi, now: now, calendar: calendar)
    }

    @Test func groupsOpenTasksOfThisMonthAndStripsSummaryTags() {
        let snapshot = make([issue("FAL-1"), issue("FAL-2", status: "Review"), issue("FAL-3", status: "To Do")])
        #expect(snapshot.rows.map(\.group) == [.doing, .review, .todo])
        #expect(snapshot.rows[0].summary == "Fix sitemap")
        #expect(snapshot.rows[0].points == "3")
        #expect(snapshot.doingCount == 1)
    }

    @Test func skipsOtherPeoplesTasks() {
        #expect(make([issue("FAL-1", assignee: "tony")]).rows.isEmpty)
    }

    @Test func countsDoneTasksInMonthStatsButNotInRows() {
        let snapshot = make([issue("FAL-1"), issue("FAL-2", status: "Done", isDone: true, points: NSNull())])
        #expect(snapshot.rows.map(\.id) == ["FAL-1"])
        #expect(snapshot.sprint.monthTasks == 2)
        #expect(snapshot.sprint.monthDone == 1)
        #expect(snapshot.sprint.monthPoints == 3)
        #expect(snapshot.sprint.pointLabel == "DP")
    }

    @Test func kpiMonthOverridesUpdatedMonth() {
        let kpi = ["FAL-1": JiraKpiEntry(month: "2026-09", devPoint: "3", testerPoint: "")]
        let snapshot = make([issue("FAL-1"), issue("FAL-2", status: "To Do", updated: "2026-08-01T10:00:00.000+0700")],
                            kpi: kpi)
        #expect(snapshot.rows.map(\.id) == ["FAL-2"])
        #expect(snapshot.sprint.monthTasks == 0)
    }

    @Test func activeSprintNameAndDaysLeft() {
        let sprint = make([]).sprint
        #expect(sprint.name == "Sprint 42")
        #expect(sprint.daysLeft == 3)
    }
}
