import Foundation

enum JiraTaskGroup: Int, CaseIterable, Identifiable {
    case doing, review, todo

    var id: Int { rawValue }
    var title: String { ["Doing", "Review & test", "To do"][rawValue] }

    static func of(status: String) -> JiraTaskGroup {
        switch status {
        case "Doing": return .doing
        case "To Do": return .todo
        default: return .review
        }
    }
}

struct JiraTaskRow: Identifiable, Equatable {
    let id: String
    let summary: String
    let status: String
    let app: String?
    let points: String?
    let isBug: Bool
    let group: JiraTaskGroup
}

struct JiraSprintStats: Equatable {
    var name = ""
    var daysLeft: Int?
    var monthTasks = 0
    var monthDone = 0
    var monthPoints = 0
    var pointLabel = "pt"
}

struct JiraMenuSnapshot: Equatable {
    static let pointLabels = ["dev": "DP", "tester": "TP", "ba": "BA pt", "designer": "DS pt"]
    private static let summaryTagsPattern = #"^(\s*\[[^\]]*\])+\s*"#

    var rows: [JiraTaskRow] = []
    var sprint = JiraSprintStats()

    var doingCount: Int { rows.filter { $0.group == .doing }.count }

    static func make(issues: [JiraJSON], meta: JiraJSON, kpi: [String: JiraKpiEntry], now: Date = Date(),
                     calendar: Calendar = .current) -> JiraMenuSnapshot {
        let me = (meta["me"] as? JiraJSON)?["name"] as? String ?? ""
        let role = meta["role"] as? String ?? JiraSettings.Role.dev.rawValue
        let currentMonth = monthKey(now, calendar: calendar)
        let mine = issues.filter { ($0["assignees"] as? [JiraJSON] ?? []).contains { $0["name"] as? String == me } }
        let thisMonth = mine.filter { month(of: $0, kpi: kpi) == currentMonth }
        let open = thisMonth.filter { $0["isDone"] as? Bool != true }
        let todoOutsideMonth = mine.filter { $0["status"] as? String == "To Do" && month(of: $0, kpi: kpi) != currentMonth }
        let active = (meta["sprints"] as? [JiraJSON] ?? []).first { $0["state"] as? String == "active" }
        let sprint = JiraSprintStats(
            name: (active?["name"] as? String ?? "").replacingOccurrences(of: "Falcon ", with: ""),
            daysLeft: parseDate(active?["endDate"]).map { daysBetween(now, $0, calendar: calendar) },
            monthTasks: thisMonth.count,
            monthDone: thisMonth.count - open.count,
            monthPoints: thisMonth.reduce(0) { $0 + (Int(rolePoint($1, role: role) ?? "") ?? 0) },
            pointLabel: pointLabels[role] ?? "pt")
        return JiraMenuSnapshot(rows: (open + todoOutsideMonth).map { row($0, role: role) }, sprint: sprint)
    }

    private static func row(_ issue: JiraJSON, role: String) -> JiraTaskRow {
        let status = issue["status"] as? String ?? ""
        let summary = (issue["summary"] as? String ?? "")
            .replacingOccurrences(of: summaryTagsPattern, with: "", options: .regularExpression)
        return JiraTaskRow(id: issue["key"] as? String ?? "", summary: summary, status: status,
                           app: issue["falconApp"] as? String, points: rolePoint(issue, role: role),
                           isBug: issue["isBug"] as? Bool == true, group: .of(status: status))
    }

    private static func rolePoint(_ issue: JiraJSON, role: String) -> String? {
        let value = (issue["rolePoints"] as? JiraJSON)?[role]
        return (value as? String) ?? (value as? NSNumber).map { "\($0)" }
    }

    private static func month(of issue: JiraJSON, kpi: [String: JiraKpiEntry]) -> String {
        kpi[issue["key"] as? String ?? ""]?.month ?? String((issue["updated"] as? String ?? "").prefix(7))
    }

    static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func daysBetween(_ from: Date, _ to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }
}
