import Foundation

typealias JiraJSON = [String: Any]

/// Pure Jira JSON → web-UI JSON mappers (port of jira-desk `service.py`), bound to one domain + field map.
struct JiraMapper {
    typealias FieldBuilder = (id: (JiraFieldMap) -> String?, build: (Any?) throws -> Any)

    static let avatarKeys = ["ownerId", "avatarId", "size"]
    static let userFieldChanges: [String: JiraField] = ["assignees": .assignees, "reviewers": .reviewers]
    static let missingAppWarning = "missing_falcon_app"
    static let doneWithoutDevPointWarning = "done_without_dev_point"

    let baseURL: String
    let fields: JiraFieldMap
    var userKey = "name"
    var pointField = JiraField.devPoint

    func summary(_ issue: JiraJSON) -> JiraJSON {
        let f = issue["fields"] as? JiraJSON ?? [:]
        let key = issue["key"] as? String ?? ""
        let status = f["status"] as? JiraJSON ?? [:]
        let sprint = Self.parseLastSprint(value(f, .sprint))
        let app = Self.optionValue(value(f, .app))
        let devPoint = Self.optionValue(value(f, pointField))
        let isDone = (status["statusCategory"] as? JiraJSON)?["key"] as? String == "done"
        var rolePoints: JiraJSON = [:]
        for role in JiraSettings.Role.allCases {
            rolePoints[role.rawValue] = orNull(Self.optionValue(value(f, JiraField.point(for: role))))
        }
        return [
            "key": key,
            "summary": f["summary"] as? String ?? "",
            "status": orNull(status["name"]),
            "statusId": orNull(status["id"]),
            "isDone": isDone,
            "type": orNull((f["issuetype"] as? JiraJSON)?["name"]),
            "priority": orNull((f["priority"] as? JiraJSON)?["name"]),
            "falconApp": orNull(app),
            "devPoint": orNull(devPoint),
            "sprint": orNull(sprint.name),
            "sprintId": orNull(sprint.id),
            "created": orNull(Self.prefix(f["created"], 10)),
            "updated": orNull(Self.prefix(f["updated"], 10)),
            "updatedAt": orNull(f["updated"] as? String),
            "resolved": orNull(Self.prefix(f["resolutiondate"], 10).flatMap { $0.isEmpty ? nil : $0 }),
            "dueDate": orNull(f["duedate"] as? String),
            "isBug": Self.isBug(f),
            "rolePoints": rolePoints,
            "parentKey": orNull(Self.pickParentKey(f)),
            "assignees": Self.users(value(f, .assignees)).map(user),
            "url": "\(baseURL)/browse/\(key)",
            "warnings": warnings(app: app, devPoint: devPoint, isDone: isDone),
        ]
    }

    func detail(_ issue: JiraJSON) -> JiraJSON {
        let f = issue["fields"] as? JiraJSON ?? [:]
        let rendered = issue["renderedFields"] as? JiraJSON ?? [:]
        let editmeta = issue["editmeta"] as? JiraJSON ?? [:]
        let comments = (rendered["comment"] as? JiraJSON)?["comments"] as? [JiraJSON] ?? []
        let transitions = issue["transitions"] as? [JiraJSON] ?? []
        var detail = summary(issue)
        detail["descriptionRaw"] = f["description"] as? String ?? ""
        detail["descriptionHtml"] = absolutizeLinks(rendered["description"] as? String)
        detail["mergeRequest"] = orNull(value(f, .mergeRequest))
        detail["reporter"] = (f["reporter"] as? JiraJSON).map(user) ?? NSNull()
        detail["attachments"] = (f["attachment"] as? [JiraJSON] ?? []).map(attachment)
        detail["extraFields"] = extraFields(f, editmeta: editmeta)
        detail["reviewers"] = fields[.reviewers] == nil ? NSNull() : Self.users(value(f, .reviewers)).map(user)
        let rawBodies = Dictionary(((f["comment"] as? JiraJSON)?["comments"] as? [JiraJSON] ?? []).compactMap { raw in
            (raw["id"] as? String).map { ($0, raw["body"] as? String ?? "") }
        }, uniquingKeysWith: { first, _ in first })
        detail["comments"] = comments.map { comment -> JiraJSON in
            let created = Self.prefix(comment["created"], 16) ?? ""
            return ["id": orNull(comment["id"]),
                    "bodyRaw": orNull((comment["id"] as? String).flatMap { rawBodies[$0] }),
                    "author": orNull((comment["author"] as? JiraJSON)?["displayName"]),
                    "authorUser": (comment["author"] as? JiraJSON).map(user) ?? NSNull(),
                    "created": created.replacingOccurrences(of: "T", with: " "),
                    "bodyHtml": absolutizeLinks(comment["body"] as? String)]
        }
        detail["transitions"] = transitions.map { transition -> JiraJSON in
            ["id": orNull(transition["id"]), "name": orNull(transition["name"]),
             "toId": orNull((transition["to"] as? JiraJSON)?["id"])]
        }
        detail["options"] = [
            "falconApp": Self.allowedValues(editmeta, fieldId: fields[.app]),
            "devPoint": Self.allowedValues(editmeta, fieldId: fields[pointField]),
            "priority": Self.allowedValues(editmeta, fieldId: "priority", labelKey: "name"),
        ]
        return detail
    }

    func attachment(_ raw: JiraJSON) -> JiraJSON {
        let content = raw["content"] as? String
        return ["id": orNull(raw["id"]), "filename": raw["filename"] as? String ?? "",
                "size": raw["size"] as? Int ?? 0, "mimeType": orNull(raw["mimeType"]),
                "created": (Self.prefix(raw["created"], 16) ?? "").replacingOccurrences(of: "T", with: " "),
                "author": orNull((raw["author"] as? JiraJSON)?["displayName"]),
                "url": orNull(content), "file": orNull(Self.proxiedFile(content)),
                "thumbnail": orNull(Self.proxiedFile(raw["thumbnail"] as? String))]
    }

    static func proxiedFile(_ absoluteURL: String?) -> String? {
        guard let absoluteURL, let components = URLComponents(string: absoluteURL), !components.path.isEmpty else { return nil }
        let path = components.path + (components.query.map { "?\($0)" } ?? "")
        return "/api/file?path=\(path.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? path)"
    }

    func user(_ raw: JiraJSON) -> JiraJSON {
        let avatarURL = (raw["avatarUrls"] as? JiraJSON)?["48x48"] as? String ?? ""
        return ["name": raw["name"] as? String ?? raw["accountId"] as? String ?? "",
                "displayName": raw["displayName"] as? String ?? "",
                "avatar": Self.localAvatarURL(avatarURL)]
    }

    func absolutizeLinks(_ html: String?) -> String {
        (html ?? "").replacing(#/(src|href)="([^"]*)"/#) { match in
            let original = "\(match.1)=\"\(match.2)\""
            let value = String(match.2)
            let path = value.hasPrefix(baseURL + "/") ? String(value.dropFirst(baseURL.count)) : value
            guard path.hasPrefix("/"), !path.hasPrefix("//") else { return original }
            guard match.1 == "src", path.hasPrefix("/secure/") else { return "\(match.1)=\"\(baseURL)\(path)\"" }
            let raw = path.replacingOccurrences(of: "&amp;", with: "&")
            return "src=\"/api/file?path=\(raw.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) ?? raw)\""
        }
    }

    static let queryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    func updateFields(_ changes: JiraJSON) throws -> JiraJSON {
        guard !changes.isEmpty else { throw JiraError(status: 400, message: "No changes to update") }
        let unknown = changes.keys.filter {
            Self.fieldBuilders[$0] == nil && Self.userFieldChanges[$0] == nil && $0 != Self.rawChange
        }.sorted()
        guard unknown.isEmpty else {
            throw JiraError(status: 400, message: "Unsupported fields: \(unknown.joined(separator: ", "))")
        }
        var update: JiraJSON = [:]
        for (name, raw) in changes {
            if name == Self.rawChange {
                try rawUpdate(raw).forEach { update[$0.key] = $0.value }
                continue
            }
            if let field = Self.userFieldChanges[name] {
                let (id, value) = try usersUpdate(name, field, raw)
                update[id] = value
                continue
            }
            let builder = Self.fieldBuilders[name]!
            guard let id = name == "devPoint" ? fields[pointField] : builder.id(fields) else {
                throw JiraError(status: 400, message: "Field \(name) is not configured for this Jira")
            }
            update[id] = try builder.build(raw)
        }
        return update
    }

    private func rawUpdate(_ raw: Any?) throws -> JiraJSON {
        guard let values = raw as? JiraJSON else { throw JiraError(status: 400, message: "raw must be an object") }
        for id in values.keys where id.wholeMatch(of: #/customfield_\d+/#) == nil {
            throw JiraError(status: 400, message: "Only custom fields can be updated directly: \(id)")
        }
        return values
    }

    private func extraFields(_ values: JiraJSON, editmeta: JiraJSON) -> [JiraJSON] {
        let meta = editmeta["fields"] as? JiraJSON ?? [:]
        let mapped: [JiraField] = [.sprint, .assignees, .app, pointField, .mergeRequest, .reviewers]
        let handled = Set(Self.panelSystemFields + mapped.compactMap { fields[$0] })
        return meta.compactMap { id, raw -> JiraJSON? in
            guard !handled.contains(id), let field = raw as? JiraJSON,
                  let kind = Self.extraKind(field["schema"] as? JiraJSON ?? [:]) else { return nil }
            return ["id": id, "name": field["name"] as? String ?? id, "kind": kind.rawValue,
                    "value": extraValue(values[id], kind),
                    "options": Self.allowedValues(editmeta, fieldId: id)]
        }
        .sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    private func extraValue(_ raw: Any?, _ kind: ExtraKind) -> Any {
        switch kind {
        case .option: return orNull(Self.optionValue(raw))
        case .users: return Self.users(raw).map(user)
        case .number: return orNull(raw as? NSNumber)
        case .text, .url, .date: return orNull(raw as? String)
        }
    }

    enum ExtraKind: String {
        case option, text, url, number, date, users
    }

    static let rawChange = "raw"
    static let panelSystemFields = ["summary", "description", "comment", "issuelinks", "priority", "duedate", "attachment"]

    static func extraKind(_ schema: JiraJSON) -> ExtraKind? {
        switch (schema["type"] as? String, schema["items"] as? String) {
        case ("option", _): return .option
        case ("string", _): return (schema["custom"] as? String ?? "").hasSuffix(":url") ? .url : .text
        case ("number", _): return .number
        case ("date", _): return .date
        case ("user", _), ("array", "user"): return .users
        default: return nil
        }
    }

    private func usersUpdate(_ name: String, _ field: JiraField, _ raw: Any?) throws -> (id: String, value: Any) {
        guard let names = raw as? [String] else { throw JiraError(status: 400, message: "\(name) must be a list of users") }
        guard let id = fields[field] ?? (field == .assignees ? "assignee" : nil) else {
            throw JiraError(status: 400, message: "Field \(name) is not configured for this Jira")
        }
        let users = names.map { [userKey: $0] }
        guard id == "assignee" else { return (id, users) }
        return (id, users.first ?? NSNull())
    }

    private func value(_ fieldValues: JiraJSON, _ field: JiraField) -> Any? {
        fields[field].flatMap { fieldValues[$0] }
    }

    private func warnings(app: String?, devPoint: String?, isDone: Bool) -> [String] {
        var warnings: [String] = []
        if fields[.app] != nil && (app ?? "").isEmpty { warnings.append(Self.missingAppWarning) }
        if isDone && fields[.devPoint] != nil && (devPoint ?? "").isEmpty {
            warnings.append(Self.doneWithoutDevPointWarning)
        }
        return warnings
    }

    static let fieldBuilders: [String: FieldBuilder] = [
        "summary": ({ _ in "summary" }, requiredText),
        "description": ({ _ in "description" }, { isBlank($0) ? "" : $0! }),
        "falconApp": ({ $0[.app] }, optionOrNull("value")),
        "devPoint": ({ $0[.devPoint] }, optionOrNull("value")),
        "priority": ({ _ in "priority" }, optionOrNull("name")),
        "dueDate": ({ _ in "duedate" }, { isBlank($0) ? NSNull() : $0! }),
        "sprintId": ({ $0[.sprint] }, sprintIdOrNull),
        "mergeRequest": ({ $0[.mergeRequest] }, { isBlank($0) ? NSNull() : $0! }),
    ]

    static func parseLastSprint(_ raw: Any?) -> (id: Int?, name: String?) {
        guard let last = (raw as? [Any])?.last else { return (nil, nil) }
        if let sprint = last as? JiraJSON { return (sprint["id"] as? Int, sprint["name"] as? String) }
        guard let text = last as? String else { return (nil, nil) }
        let id = text.firstMatch(of: #/[\[,]id=(\d+)/#).flatMap { Int($0.1) }
        let name = text.firstMatch(of: #/[\[,]name=([^,\]]+)/#).map { String($0.1) }
        return (id, name)
    }

    static func isBug(_ fields: JiraJSON) -> Bool {
        (fields["issuetype"] as? JiraJSON)?["name"] as? String == "Bug"
            || (fields["summary"] as? String ?? "").hasPrefix("[BUG]")
    }

    static func pickParentKey(_ fields: JiraJSON) -> String? {
        if let parentKey = (fields["parent"] as? JiraJSON)?["key"] as? String { return parentKey }
        guard isBug(fields) else { return nil }
        for link in fields["issuelinks"] as? [JiraJSON] ?? [] {
            guard let other = (link["outwardIssue"] as? JiraJSON) ?? (link["inwardIssue"] as? JiraJSON),
                  !isBug(other["fields"] as? JiraJSON ?? [:]) else { continue }
            return other["key"] as? String
        }
        return nil
    }

    static func pickTransition(_ transitions: [JiraJSON], statusIds: [String]) -> String? {
        transitions.first { statusIds.contains((($0["to"] as? JiraJSON)?["id"] as? String) ?? "") }?["id"] as? String
    }

    static func localAvatarURL(_ jiraAvatarURL: String) -> String {
        "/api/avatar?\(URLComponents(string: jiraAvatarURL)?.percentEncodedQuery ?? "")"
    }

    static func avatarParams(_ query: String) throws -> [String: String] {
        let items = URLComponents(string: "?\(query)")?.queryItems ?? []
        var params: [String: String] = [:]
        for key in avatarKeys {
            if let value = items.first(where: { $0.name == key })?.value { params[key] = value }
        }
        guard params["avatarId"] != nil else { throw JiraError(status: 400, message: "avatarId is required") }
        guard params.values.allSatisfy({ $0.wholeMatch(of: #/[A-Za-z0-9_]+/#) != nil }) else {
            throw JiraError(status: 400, message: "Invalid avatar parameter")
        }
        return params
    }

    static func users(_ raw: Any?) -> [JiraJSON] {
        if let list = raw as? [JiraJSON] { return list }
        if let single = raw as? JiraJSON { return [single] }
        return []
    }

    static func optionValue(_ raw: Any?) -> String? {
        if let option = raw as? JiraJSON { return option["value"] as? String }
        if let number = raw as? NSNumber { return number.stringValue }
        return raw as? String
    }

    static func allowedValues(_ editmeta: JiraJSON, fieldId: String?, labelKey: String = "value") -> [String] {
        guard let fieldId, let field = (editmeta["fields"] as? JiraJSON)?[fieldId] as? JiraJSON else { return [] }
        return (field["allowedValues"] as? [JiraJSON] ?? []).compactMap { $0[labelKey] as? String }
    }

    private static func prefix(_ raw: Any?, _ length: Int) -> String? {
        (raw as? String).map { String($0.prefix(length)) }
    }

    private static func isBlank(_ raw: Any?) -> Bool {
        raw == nil || raw is NSNull || (raw as? String) == ""
    }

    private static func requiredText(_ raw: Any?) throws -> Any {
        let text = isBlank(raw) ? "" : String(describing: raw!).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw JiraError(status: 400, message: "Summary cannot be empty") }
        return text
    }

    private static func optionOrNull(_ key: String) -> (Any?) throws -> Any {
        { raw in isBlank(raw) ? NSNull() : [key: String(describing: raw!)] }
    }

    private static func sprintIdOrNull(_ raw: Any?) throws -> Any {
        if isBlank(raw) { return NSNull() }
        if let id = raw as? Int { return id }
        guard let id = Int(String(describing: raw!)) else {
            throw JiraError(status: 400, message: "Invalid sprint id: \(raw!)")
        }
        return id
    }
}

func orNull(_ value: Any?) -> Any { value ?? NSNull() }

/// One issue's KPI attribution as stored in `jira-kpi.json`.
struct JiraKpiEntry: Codable, Equatable {
    var month: String
    var devPoint: String
    var testerPoint: String
    var source: String?
}

/// KPI sheet parsing (CSV rows) and the "counted elsewhere" merge.
enum JiraKpi {
    static let countedElsewhereSource = "countedElsewhere"
    static let monthColumn = 0
    static let linkColumn = 3
    static let devPointColumn = 4
    static let testerPointColumn = 5

    static func parseMonth(_ label: String) -> String? {
        guard let match = label.trimmingCharacters(in: .whitespaces).wholeMatch(of: #/T(\d{1,2})\s+(\d{2})/#),
              let month = Int(match.1) else { return nil }
        return String(format: "20%@-%02d", String(match.2), month)
    }

    static func parseRows(_ rows: [[String]], projectKey: String) -> [String: JiraKpiEntry] {
        guard let keyPattern = try? Regex("\\b\(NSRegularExpression.escapedPattern(for: projectKey))-\\d+\\b")
            .wordBoundaryKind(.simple) else { return [:] }
        var kpi: [String: JiraKpiEntry] = [:]
        for row in rows.dropFirst() {
            guard let month = parseMonth(cell(row, monthColumn)),
                  let keyMatch = cell(row, linkColumn).firstMatch(of: keyPattern) else { continue }
            let key = String(cell(row, linkColumn)[keyMatch.range])
            if let existing = kpi[key], existing.month >= month { continue }
            kpi[key] = JiraKpiEntry(month: month, devPoint: cell(row, devPointColumn),
                                    testerPoint: cell(row, testerPointColumn))
        }
        return kpi
    }

    static func addCountedElsewhere(_ kpi: [String: JiraKpiEntry], keys: [String],
                                    month: String) -> [String: JiraKpiEntry] {
        var merged = Dictionary(keys.map {
            ($0, JiraKpiEntry(month: month, devPoint: "", testerPoint: "", source: countedElsewhereSource))
        }, uniquingKeysWith: { first, _ in first })
        merged.merge(kpi) { _, sheet in sheet }
        return merged
    }

    private static func cell(_ row: [String], _ index: Int) -> String {
        index < row.count ? row[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}

enum JiraCSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var characters = text.makeIterator()
        var pending = characters.next()
        while let character = pending {
            pending = characters.next()
            if inQuotes {
                if character != "\"" {
                    field.append(character)
                } else if pending == "\"" {
                    field.append(character)
                    pending = characters.next()
                } else {
                    inQuotes = false
                }
                continue
            }
            switch character {
            case "\"": inQuotes = true
            case ",":
                row.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default: field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

struct JiraWatchFields: Equatable {
    let assignees: [String]
    let reviewers: String?

    var jqlFields: String {
        (["summary", "updated", "description", "comment"] + assignees + [reviewers].compactMap { $0 }).joined(separator: ",")
    }
}

enum JiraChanges {
    static func changedKeys(_ issues: [JiraJSON], seen: [String: String]) -> (keys: [String], seen: [String: String]) {
        var current: [String: String] = [:]
        var keys: [String] = []
        for issue in issues {
            guard let key = issue["key"] as? String else { continue }
            let updated = (issue["fields"] as? JiraJSON)?["updated"] as? String ?? ""
            current[key] = updated
            if seen[key] != updated { keys.append(key) }
        }
        return (keys, current)
    }
}

struct JiraWatchState: Codable, Equatable {
    var knownAssigned: Set<String>
    var knownReviewing: Set<String>
    var notifiedComments: Set<String> = []
    var mentionedIn: Set<String> = []
    var since: Date
}

struct JiraEvent: Equatable {
    enum Kind: String {
        case assigned
        case reviewer
        case comment
        case mention
    }

    let kind: Kind
    let key: String
    let title: String
    let message: String
}

enum JiraEvents {
    static let commentPreviewChars = 120
    private static let jiraTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    static func detect(_ issues: [JiraJSON], me: String, fields: JiraWatchFields,
                       state: JiraWatchState) -> (events: [JiraEvent], state: JiraWatchState) {
        var events: [JiraEvent] = []
        var next = state
        for issue in issues {
            let key = issue["key"] as? String ?? ""
            let values = issue["fields"] as? JiraJSON ?? [:]
            let summary = values["summary"] as? String ?? ""
            let isMine = fields.assignees.contains { includes(values[$0], me) }
            let isReviewer = fields.reviewers.map { includes(values[$0], me) } ?? false
            if track(key, isMine, in: &next.knownAssigned) {
                events.append(JiraEvent(kind: .assigned, key: key, title: key, message: "You were added to: \(summary)"))
            }
            if track(key, isReviewer, in: &next.knownReviewing) {
                events.append(JiraEvent(kind: .reviewer, key: key, title: key,
                                        message: "You were added as reviewer: \(summary)"))
            }
            if track(key, mentions(values["description"] as? String ?? "", me), in: &next.mentionedIn) {
                events.append(JiraEvent(kind: .mention, key: key, title: "\(key) · \(summary)",
                                        message: "You were mentioned in the description"))
            }
            for comment in (values["comment"] as? JiraJSON)?["comments"] as? [JiraJSON] ?? [] {
                guard let id = comment["id"] as? String, !next.notifiedComments.contains(id),
                      isRelevant(comment, me: me, isMine: isMine || isReviewer, since: state.since) else { continue }
                next.notifiedComments.insert(id)
                events.append(commentEvent(key: key, summary: summary, comment: comment, isMine: isMine || isReviewer))
            }
        }
        return (events, next)
    }

    private static func track(_ key: String, _ isOn: Bool, in known: inout Set<String>) -> Bool {
        guard isOn else {
            known.remove(key)
            return false
        }
        return known.insert(key).inserted
    }

    private static func includes(_ users: Any?, _ me: String) -> Bool {
        JiraMapper.users(users).contains { identity($0) == me }
    }

    private static func identity(_ user: JiraJSON) -> String? {
        user["name"] as? String ?? user["accountId"] as? String
    }

    private static func mentions(_ text: String, _ me: String) -> Bool {
        text.contains("[~\(me)]") || text.contains("[~accountid:\(me)]")
    }

    private static func isRelevant(_ comment: JiraJSON, me: String, isMine: Bool, since: Date) -> Bool {
        guard identity(comment["author"] as? JiraJSON ?? [:]) != me else { return false }
        let times = ["created", "updated"].compactMap { (comment[$0] as? String).flatMap(jiraTimeFormatter.date(from:)) }
        guard times.contains(where: { $0 > since }) else { return false }
        return isMine || mentions(comment["body"] as? String ?? "", me)
    }

    private static func commentEvent(key: String, summary: String, comment: JiraJSON, isMine: Bool) -> JiraEvent {
        let body = comment["body"] as? String ?? ""
        let preview = body.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(commentPreviewChars)
        let author = (comment["author"] as? JiraJSON)?["displayName"] as? String ?? ""
        return JiraEvent(kind: isMine ? .comment : .mention, key: key, title: "\(key) · \(summary)",
                         message: "\(author): \(preview)")
    }
}
