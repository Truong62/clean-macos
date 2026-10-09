import Foundation

/// Central UserDefaults keys + typed accessors for the Jira feature.
enum JiraSettings {
    enum AuthKind: String, CaseIterable {
        case server
        case cloud
    }

    enum Role: String, CaseIterable {
        case dev
        case tester
        case ba
        case designer
    }

    static let domainKey = "jira.domain"
    static let authKindKey = "jira.authKind"
    static let emailKey = "jira.email"
    static let projectKeyKey = "jira.projectKey"
    static let boardIdKey = "jira.boardId"
    static let roleKey = "jira.role"
    static let appFieldNameKey = "jira.appFieldName"
    static let menuBarEnabledKey = "jira.menuBarEnabled"
    static let notificationsEnabledKey = "jira.notificationsEnabled"
    static let kpiCountedElsewhereJQLKey = "jira.kpiCountedElsewhereJQL"
    static let kpiCountedElsewhereMonthKey = "jira.kpiCountedElsewhereMonth"

    static func fieldOverrideKey(_ field: JiraField) -> String { "jira.field.\(field.rawValue)" }

    private static var defaults: UserDefaults { .standard }

    static var domain: String {
        get { normalizedDomain(defaults.string(forKey: domainKey) ?? "") }
        set { defaults.set(normalizedDomain(newValue), forKey: domainKey) }
    }

    static var authKind: AuthKind {
        get { defaults.string(forKey: authKindKey).flatMap(AuthKind.init(rawValue:)) ?? .server }
        set { defaults.set(newValue.rawValue, forKey: authKindKey) }
    }

    static var email: String {
        get { defaults.string(forKey: emailKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: emailKey) }
    }

    static var projectKey: String {
        get { defaults.string(forKey: projectKeyKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces).uppercased(), forKey: projectKeyKey) }
    }

    static var boardId: Int? {
        get { defaults.object(forKey: boardIdKey) as? Int }
        set { defaults.set(newValue, forKey: boardIdKey) }
    }

    static var role: Role {
        get { defaults.string(forKey: roleKey).flatMap(Role.init(rawValue:)) ?? .dev }
        set { defaults.set(newValue.rawValue, forKey: roleKey) }
    }

    static var appFieldName: String {
        get { defaults.string(forKey: appFieldNameKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: appFieldNameKey) }
    }

    static var fieldOverrides: [JiraField: String] {
        var overrides: [JiraField: String] = [:]
        for field in JiraField.allCases {
            if let id = fieldOverride(field) { overrides[field] = id }
        }
        return overrides
    }

    static func fieldOverride(_ field: JiraField) -> String? {
        let id = defaults.string(forKey: fieldOverrideKey(field))?.trimmingCharacters(in: .whitespaces) ?? ""
        return id.isEmpty ? nil : id
    }

    static func setFieldOverride(_ field: JiraField, id: String?) {
        defaults.set(id?.trimmingCharacters(in: .whitespaces), forKey: fieldOverrideKey(field))
    }

    static var menuBarEnabled: Bool {
        get { defaults.object(forKey: menuBarEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: menuBarEnabledKey) }
    }

    static var notificationsEnabled: Bool {
        get { defaults.object(forKey: notificationsEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: notificationsEnabledKey) }
    }

    static var kpiCountedElsewhereJQL: String {
        get { defaults.string(forKey: kpiCountedElsewhereJQLKey) ?? "" }
        set { defaults.set(newValue, forKey: kpiCountedElsewhereJQLKey) }
    }

    static var kpiCountedElsewhereMonth: String {
        get { defaults.string(forKey: kpiCountedElsewhereMonthKey) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: kpiCountedElsewhereMonthKey) }
    }

    static func normalizedDomain(_ raw: String) -> String {
        var domain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while domain.hasSuffix("/") { domain.removeLast() }
        return domain
    }
}
