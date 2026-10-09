import Foundation

/// Jira use cases behind the web UI's `/api/*` routes (port of jira-desk `IssueService`).
actor JiraService {
    static let pageSize = 1000
    static let userSearchLimit = 20
    static let detailExpand = "renderedFields,transitions,editmeta"
    static let sprintStates = "active,future"
    static let standardListFields = ["summary", "status", "issuetype", "priority", "created", "updated",
                                     "resolutiondate", "duedate", "parent", "issuelinks"]

    let client: JiraClient
    let projectKey: String
    let boardId: Int?
    let role: JiraSettings.Role
    private let appFieldName: String
    private let fieldOverrides: [JiraField: String]
    private var cachedFieldMap: JiraFieldMap?

    init(client: JiraClient,
         projectKey: String = JiraSettings.projectKey,
         boardId: Int? = JiraSettings.boardId,
         role: JiraSettings.Role = JiraSettings.role,
         appFieldName: String = JiraSettings.appFieldName,
         fieldOverrides: [JiraField: String] = JiraSettings.fieldOverrides) {
        self.client = client
        self.projectKey = projectKey
        self.boardId = boardId
        self.role = role
        self.appFieldName = appFieldName
        self.fieldOverrides = fieldOverrides
    }

    func fieldMap() async throws -> JiraFieldMap {
        if let cachedFieldMap { return cachedFieldMap }
        let fields = try await client.json(path: "/rest/api/2/field") as? [JiraJSON] ?? []
        let map = JiraFieldDiscovery.discover(fields: fields, appFieldName: appFieldName, overrides: fieldOverrides)
        cachedFieldMap = map
        return map
    }

    func listIssues() async throws -> [JiraJSON] {
        guard !projectKey.isEmpty else { throw JiraError(status: 400, message: "Jira project key is not set") }
        let mapper = try await mapper()
        let issues = try await search(jql: "project = \(projectKey) ORDER BY updated DESC",
                                      fields: listFields(mapper.fields))
        return issues.map(mapper.summary)
    }

    func listCountedElsewhereKeys(jql: String) async throws -> [String] {
        try await search(jql: jql, fields: "key").compactMap { $0["key"] as? String }
    }

    func search(jql: String, fields: String) async throws -> [JiraJSON] {
        client.authKind == .cloud
            ? try await searchCloud(jql: jql, fields: fields)
            : try await searchServer(jql: jql, fields: fields)
    }

    func getIssue(_ key: String) async throws -> JiraJSON {
        try Self.validate(key: key)
        let issue = try await object(path: "/rest/api/2/issue/\(key)", query: ["expand": Self.detailExpand])
        return try await mapper().detail(issue)
    }

    func updateIssue(_ key: String, changes: JiraJSON) async throws -> JiraJSON {
        try Self.validate(key: key)
        let fields = try await mapper().updateFields(changes)
        _ = try await client.request(method: "PUT", path: "/rest/api/2/issue/\(key)", body: ["fields": fields])
        return try await getIssue(key)
    }

    func transitionIssue(_ key: String, transitionId: String) async throws -> JiraJSON {
        try Self.validate(key: key)
        guard !transitionId.isEmpty else { throw JiraError(status: 400, message: "Transition id is required") }
        _ = try await client.request(method: "POST", path: "/rest/api/2/issue/\(key)/transitions",
                                     body: ["transition": ["id": transitionId]])
        return try await getIssue(key)
    }

    func moveIssue(_ key: String, column columnName: String) async throws -> JiraJSON {
        try Self.validate(key: key)
        guard let column = try await getBoardColumns().first(where: { $0["name"] as? String == columnName }) else {
            throw JiraError(status: 400, message: "Unknown board column '\(columnName)'")
        }
        let transitions = try await object(path: "/rest/api/2/issue/\(key)/transitions")["transitions"]
        guard let transitionId = JiraMapper.pickTransition(transitions as? [JiraJSON] ?? [],
                                                           statusIds: column["statusIds"] as? [String] ?? []) else {
            throw JiraError(status: 400, message: "\(key) cannot move to '\(columnName)' from its current status")
        }
        return try await transitionIssue(key, transitionId: transitionId)
    }

    func addComment(_ key: String, body: String) async throws -> JiraJSON {
        try Self.validate(key: key)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JiraError(status: 400, message: "Comment cannot be empty")
        }
        _ = try await client.request(method: "POST", path: "/rest/api/2/issue/\(key)/comment", body: ["body": body])
        return try await getIssue(key)
    }

    func getBoardColumns() async throws -> [JiraJSON] {
        guard let boardId else { throw JiraError(status: 400, message: "Jira board is not set") }
        let config = try await object(path: "/rest/agile/1.0/board/\(boardId)/configuration")
        let columns = (config["columnConfig"] as? JiraJSON)?["columns"] as? [JiraJSON] ?? []
        return columns.map { column in
            let statuses = column["statuses"] as? [JiraJSON] ?? []
            return ["name": orNull(column["name"]), "statusIds": statuses.compactMap { $0["id"] as? String }]
        }
    }

    func getMeta() async throws -> JiraJSON {
        let mapper = try await mapper()
        let me = try await object(path: "/rest/api/2/myself")
        let pointField = JiraField.point(for: role)
        return [
            "me": mapper.user(me),
            "role": role.rawValue,
            "columns": boardId == nil ? [] : try await getBoardColumns(),
            "sprints": try await openSprints(),
            "labels": [
                "app": orNull(mapper.fields[.app] == nil ? nil : mapper.fields.names[.app]),
                "points": orNull(mapper.fields[pointField] == nil ? nil : mapper.fields.names[pointField]),
            ] as JiraJSON,
        ]
    }

    func importKpi(csv: String, countedElsewhereJQL: String, countedElsewhereMonth: String,
                   now: Date = Date()) async throws -> JiraKpiData {
        var issues = JiraKpi.parseRows(JiraCSV.parse(csv), projectKey: projectKey)
        guard !issues.isEmpty else {
            throw JiraError(status: 400, message: "No KPI rows found — expected columns: Month (T9 26), …, task link with \(projectKey)-…, Dev point, Tester point")
        }
        let jql = countedElsewhereJQL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !jql.isEmpty {
            guard countedElsewhereMonth.wholeMatch(of: #/\d{4}-\d{2}/#) != nil else {
                throw JiraError(status: 400, message: "Counted-elsewhere month must look like 2026-06")
            }
            let keys = try await listCountedElsewhereKeys(jql: jql)
            issues = JiraKpi.addCountedElsewhere(issues, keys: keys, month: countedElsewhereMonth)
        }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        return JiraKpiData(syncedAt: day.string(from: now), issues: issues)
    }

    func searchUsers(_ query: String) async throws -> [JiraJSON] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let param = client.authKind == .cloud ? "query" : "username"
        let users = try await client.json(path: "/rest/api/2/user/search",
                                          query: [param: text, "maxResults": "\(Self.userSearchLimit)"]) as? [JiraJSON] ?? []
        let mapper = try await mapper()
        return users.map(mapper.user)
    }

    func myIdentity() async throws -> String {
        let me = try await object(path: "/rest/api/2/myself")
        return me["name"] as? String ?? me["accountId"] as? String ?? ""
    }

    func watchFields() async throws -> JiraWatchFields {
        let map = try await fieldMap()
        let assignees = [map[.assignees], "assignee"].compactMap { $0 }
        return JiraWatchFields(assignees: assignees.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
                               reviewers: map[.reviewers])
    }

    func myKeys(inAnyOf fieldIds: [String]) async throws -> Set<String> {
        guard !fieldIds.isEmpty else { return [] }
        let clause = fieldIds.map { "\(Self.jqlName($0)) = currentUser()" }.joined(separator: " OR ")
        return Set(try await search(jql: clause, fields: "key").compactMap { $0["key"] as? String })
    }

    func issuesUpdated(since: Date, fields: JiraWatchFields, now: Date = Date()) async throws -> [JiraJSON] {
        let minutes = max(1, Int((now.timeIntervalSince(since) / 60).rounded(.up)))
        return try await search(jql: "updated >= -\(minutes)m ORDER BY updated DESC", fields: fields.jqlFields)
    }

    static func jqlName(_ fieldId: String) -> String {
        fieldId.hasPrefix("customfield_") ? "cf[\(fieldId.dropFirst("customfield_".count))]" : fieldId
    }

    func avatar(query: String) async throws -> (data: Data, contentType: String) {
        try await client.requestRaw(path: "/secure/useravatar", query: JiraMapper.avatarParams(query))
    }

    private func mapper() async throws -> JiraMapper {
        JiraMapper(baseURL: client.baseURL, fields: try await fieldMap(),
                   userKey: client.authKind == .cloud ? "accountId" : "name", pointField: JiraField.point(for: role))
    }

    private func object(path: String, query: [String: String] = [:]) async throws -> JiraJSON {
        try await client.json(path: path, query: query) as? JiraJSON ?? [:]
    }

    private func listFields(_ fields: JiraFieldMap) -> String {
        let custom: [JiraField] = [.app, .sprint, .assignees, .devPoint, .testerPoint, .baPoint, .designerPoint]
        return (Self.standardListFields + custom.compactMap { fields[$0] }).joined(separator: ",")
    }

    private func searchServer(jql: String, fields: String) async throws -> [JiraJSON] {
        var issues: [JiraJSON] = []
        while true {
            let page = try await object(path: "/rest/api/2/search", query: [
                "jql": jql, "fields": fields, "maxResults": "\(Self.pageSize)", "startAt": "\(issues.count)",
            ])
            let batch = page["issues"] as? [JiraJSON] ?? []
            issues += batch
            if batch.isEmpty || issues.count >= page["total"] as? Int ?? 0 { return issues }
        }
    }

    private func searchCloud(jql: String, fields: String) async throws -> [JiraJSON] {
        var issues: [JiraJSON] = []
        var pageToken: String?
        repeat {
            var query = ["jql": jql, "fields": fields, "maxResults": "\(Self.pageSize)"]
            query["nextPageToken"] = pageToken
            let page = try await object(path: "/rest/api/2/search/jql", query: query)
            issues += page["issues"] as? [JiraJSON] ?? []
            pageToken = page["isLast"] as? Bool == true ? nil : page["nextPageToken"] as? String
        } while pageToken != nil
        return issues
    }

    private func openSprints() async throws -> [JiraJSON] {
        guard let boardId else { return [] }
        let page: JiraJSON
        do {
            page = try await object(path: "/rest/agile/1.0/board/\(boardId)/sprint", query: ["state": Self.sprintStates])
        } catch let error as JiraError where error.status == 400 {
            return []
        }
        return (page["values"] as? [JiraJSON] ?? []).map { sprint in
            ["id": orNull(sprint["id"]), "name": orNull(sprint["name"]), "state": orNull(sprint["state"]),
             "startDate": orNull(sprint["startDate"]), "endDate": orNull(sprint["endDate"])]
        }
    }

    private static func validate(key: String) throws {
        guard key.wholeMatch(of: #/[A-Z][A-Z0-9_]*-\d+/#) != nil else {
            throw JiraError(status: 400, message: "Invalid issue key '\(key)'")
        }
    }
}
