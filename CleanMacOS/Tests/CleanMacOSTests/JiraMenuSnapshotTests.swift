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
        ["key": key, "summary": "[SEO] [Bug] Fix sitemap", "status": status, "updated": String(updated.prefix(10)),
         "updatedAt": updated, "isDone": isDone,
         "falconApp": "SEO", "isBug": false, "rolePoints": ["dev": points], "assignees": [["name": assignee]]]
    }

    private func make(_ issues: [JiraJSON], kpi: [String: JiraKpiEntry] = [:]) -> JiraMenuSnapshot {
        JiraMenuSnapshot.make(issues: issues, meta: meta, kpi: kpi, now: now, calendar: calendar)
    }

    @Test func groupsDoingThenRecentThenTodoAndStripsSummaryTags() {
        let snapshot = make([issue("FAL-1"), issue("FAL-2", status: "Review"), issue("FAL-3", status: "To Do")])
        #expect(snapshot.rows.map(\.group) == [.doing, .recent, .todo])
        #expect(snapshot.rows[0].summary == "Fix sitemap")
        #expect(snapshot.rows[0].points == "3")
        #expect(snapshot.doingCount == 1)
    }

    @Test func recentShowsThreeLatestUpdatesOfAnyStatusExceptDoing() {
        let snapshot = make([
            issue("FAL-1", updated: "2026-10-09T09:00:00.000+0700"),
            issue("FAL-2", status: "Review", updated: "2026-10-08T08:00:00.000+0700"),
            issue("FAL-3", status: "Done", updated: "2026-10-09T08:30:00.000+0700", isDone: true),
            issue("FAL-4", status: "Waiting To Test", updated: "2026-10-09T08:45:00.000+0700"),
            issue("FAL-5", status: "Review", updated: "2026-09-01T08:00:00.000+0700"),
        ])
        #expect(snapshot.rows.filter { $0.group == .recent }.map(\.id) == ["FAL-4", "FAL-3", "FAL-2"])
        #expect(snapshot.rows.first { $0.id == "FAL-3" }?.isDone == true)
    }

    @Test func skipsOtherPeoplesTasks() {
        #expect(make([issue("FAL-1", assignee: "tony")]).rows.isEmpty)
    }

    @Test func countsDoneTasksInMonthStatsButNotInRows() {
        let snapshot = make([issue("FAL-1"), issue("FAL-2", status: "Done", isDone: true, points: NSNull())])
        #expect(snapshot.rows.filter { $0.group == .doing }.map(\.id) == ["FAL-1"])
        #expect(snapshot.rows.filter { $0.group == .recent }.map(\.id) == ["FAL-2"])
        #expect(snapshot.sprint.monthTasks == 2)
        #expect(snapshot.sprint.monthDone == 1)
        #expect(snapshot.sprint.monthPoints == 3)
        #expect(snapshot.sprint.pointLabel == "DP")
    }

    @Test func kpiMonthOverridesUpdatedMonth() {
        let kpi = ["FAL-1": JiraKpiEntry(month: "2026-09", devPoint: "3", testerPoint: "")]
        let snapshot = make([issue("FAL-1"), issue("FAL-2", status: "To Do", updated: "2026-08-01T10:00:00.000+0700")],
                            kpi: kpi)
        #expect(snapshot.rows.filter { $0.group == .todo }.map(\.id) == ["FAL-2"])
        #expect(snapshot.sprint.monthTasks == 0)
    }

    @Test func activeSprintNameAndDaysLeft() {
        let sprint = make([]).sprint
        #expect(sprint.name == "Sprint 42")
        #expect(sprint.daysLeft == 3)
    }
}
