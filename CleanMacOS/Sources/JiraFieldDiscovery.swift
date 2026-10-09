import Foundation

/// Jira fields the app reads/writes beyond the standard ones; raw value is the settings suffix.
enum JiraField: String, CaseIterable {
    case sprint
    case assignees
    case app
    case devPoint
    case testerPoint
    case baPoint
    case designerPoint
    case mergeRequest
    case reviewers

    static func point(for role: JiraSettings.Role) -> JiraField {
        switch role {
        case .dev: return .devPoint
        case .tester: return .testerPoint
        case .ba: return .baPoint
        case .designer: return .designerPoint
        }
    }
}

/// Resolved Jira field ids + display names for one Jira instance.
struct JiraFieldMap: Equatable {
    var ids: [JiraField: String] = [:]
    var names: [JiraField: String] = [:]

    subscript(field: JiraField) -> String? { ids[field] }
}

/// Maps `/rest/api/2/field` to a `JiraFieldMap` by field name; overrides win.
enum JiraFieldDiscovery {
    static let standardAssignee = (id: "assignee", name: "Assignee")
    static let fieldNames: [JiraField: String] = [
        .sprint: "Sprint",
        .assignees: "Assignees",
        .devPoint: "Dev Point",
        .testerPoint: "Tester Point",
        .baPoint: "BA Point",
        .designerPoint: "Designer Point",
        .mergeRequest: "Merge Request",
        .reviewers: "Reviewer",
    ]

    static func discover(fields: [[String: Any]], appFieldName: String = "",
                         overrides: [JiraField: String] = [:]) -> JiraFieldMap {
        var names = fieldNames
        if !appFieldName.isEmpty { names[.app] = appFieldName }
        var map = JiraFieldMap()
        for (field, wanted) in names {
            guard let match = fields.first(where: {
                ($0["name"] as? String)?.caseInsensitiveCompare(wanted) == .orderedSame
            }), let id = match["id"] as? String else { continue }
            map.ids[field] = id
            map.names[field] = match["name"] as? String
        }
        if map.ids[.assignees] == nil {
            map.ids[.assignees] = standardAssignee.id
            map.names[.assignees] = standardAssignee.name
        }
        for (field, id) in overrides {
            map.ids[field] = id
            map.names[field] = fields.first { $0["id"] as? String == id }?["name"] as? String ?? id
        }
        return map
    }
}
