import SwiftUI

struct JiraSettingsForm: View {
    @EnvironmentObject var jira: JiraViewModel
    var showsAdvanced = true
    @AppStorage(JiraSettings.domainKey) private var domain = ""
    @AppStorage(JiraSettings.emailKey) private var email = ""
    @AppStorage(JiraSettings.projectKeyKey) private var projectKey = ""
    @AppStorage(JiraSettings.appFieldNameKey) private var appFieldName = ""
    @AppStorage(JiraSettings.roleKey) private var role = JiraSettings.Role.dev.rawValue
    @AppStorage(JiraSettings.kpiCountedElsewhereJQLKey) private var countedElsewhereJQL = ""
    @AppStorage(JiraSettings.kpiCountedElsewhereMonthKey) private var countedElsewhereMonth = ""
    @AppStorage(JiraSettings.menuBarEnabledKey) private var menuBarEnabled = true
    @AppStorage(JiraSettings.notificationsEnabledKey) private var notificationsEnabled = true
    @State private var boardId = JiraSettings.boardId
    @State private var token = ""
    @State private var status = ""
    @State private var isTesting = false
    @State private var projects: [JiraProjectOption] = []
    @State private var boards: [JiraBoardOption] = []
    @State private var showsMore = false

    private var isCloud: Bool { JiraSettings.AuthKind(domain: JiraSettings.normalizedDomain(domain)) == .cloud }

    var body: some View {
        row("Jira URL", "Paste any link from your Jira site") {
            TextField("https://yourcompany.atlassian.net", text: $domain).textFieldStyle(.roundedBorder).frame(width: 300)
        }
        if isCloud {
            row("Email", "Your Atlassian account email") {
                TextField("you@company.com", text: $email).textFieldStyle(.roundedBorder).frame(width: 300)
            }
        }
        tokenRow
        HStack {
            Button(jira.service == nil ? "Connect" : "Save & Reconnect", action: saveAndTest)
                .buttonStyle(.borderedProminent)
                .disabled(isTesting)
                .pointerCursor()
            if isTesting { ProgressView().controlSize(.small) }
            Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if jira.service != nil { projectRows }
        if showsAdvanced {
            preferenceRows
            DisclosureGroup("Advanced", isExpanded: $showsMore) {
                VStack(alignment: .leading, spacing: 16) { advancedRows }.padding(.top, 8)
            }
        }
    }

    private var tokenRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token").fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(jira.hasToken ? "Saved on this Mac — type to replace" : (isCloud ? "Atlassian API token" : "Personal Access Token"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = JiraSettings.tokenPageURL(domain: JiraSettings.normalizedDomain(domain)) {
                        Link("Create one ↗", destination: url).font(.caption).pointerCursor()
                    }
                }
            }
            Spacer()
            SecureField(jira.hasToken ? "••••••••" : "Paste token", text: $token).textFieldStyle(.roundedBorder).frame(width: 300)
        }
    }

    @ViewBuilder private var projectRows: some View {
        row("Project", "Tasks of this project are listed") {
            if projects.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading projects…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 300, alignment: .leading)
            } else {
                Picker("", selection: Binding(get: { projectKey }, set: selectProject)) {
                    if projectKey.isEmpty { Text("Choose a project…").tag("") }
                    ForEach(projects) { Text("\($0.name) (\($0.key))").tag($0.key) }
                }
                .labelsHidden()
                .frame(width: 300, alignment: .trailing)
            }
        }
        .task(id: jira.service.map(ObjectIdentifier.init)) { await loadProjects() }
        if boards.count > 1 {
            row("Board", "Columns and sprints come from this board") {
                Picker("", selection: Binding(get: { boardId }, set: selectBoard)) {
                    ForEach(boards) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(width: 300, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var preferenceRows: some View {
        row("Role", "Which point field counts for you") {
            Picker("", selection: $role) {
                ForEach(JiraSettings.Role.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
        }
        Toggle(isOn: $menuBarEnabled) { label("Show tasks in menu bar", "Sprint, month progress and your open tasks") }
            .onChange(of: menuBarEnabled) { _, _ in jira.restartBackgroundWork() }
        HStack {
            Toggle(isOn: $notificationsEnabled) {
                label("Notifications", "Added to a task, people joining or leaving your task, new comment, @mention")
            }
            .onChange(of: notificationsEnabled) { _, _ in jira.restartBackgroundWork() }
            Spacer()
            Button("Send Test") { Task { status = await jira.sendTestNotification() } }
                .pointerCursor()
        }
    }

    @ViewBuilder private var advancedRows: some View {
        row("App field", "Custom field shown as the app tag (optional)") {
            TextField("Falcon App", text: $appFieldName).textFieldStyle(.roundedBorder).frame(width: 300)
                .onSubmit { jira.reload() }
        }
        row("KPI counted elsewhere", "Optional JQL for tasks already counted outside the sheet, and their month") {
            HStack(spacing: 6) {
                TextField(#"description ~ "KPI đã tính ở Notion""#, text: $countedElsewhereJQL).textFieldStyle(.roundedBorder)
                TextField("2026-06", text: $countedElsewhereMonth).textFieldStyle(.roundedBorder).frame(width: 80)
            }
            .frame(width: 300)
        }
        row("KPI sheet", "Import a CSV export: Month (T9 26), …, task link, Dev point, Tester point") {
            Button("Import KPI CSV…", action: importKpi).pointerCursor()
        }
    }

    private func importKpi() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isTesting = true
        Task {
            status = await jira.importKpi(from: url)
            isTesting = false
        }
    }

    private func saveAndTest() {
        JiraSettings.domain = domain
        domain = JiraSettings.domain
        JiraSettings.email = email
        do {
            if !token.isEmpty { try jira.saveToken(token) }
        } catch {
            status = error.localizedDescription
            return
        }
        token = ""
        jira.reload()
        isTesting = true
        Task {
            status = await jira.testConnection()
            isTesting = false
        }
    }

    private func loadProjects() async {
        guard let service = jira.service else { return }
        do {
            projects = try await service.listProjects()
            guard !projectKey.isEmpty else { return }
            boards = try await service.listBoards(projectKey: projectKey)
            if boardId == nil, let board = JiraBoardOption.preferred(in: boards, current: nil) { selectBoard(board.id) }
        } catch {
            status = error.localizedDescription
        }
    }

    private func selectProject(_ key: String) {
        guard key != projectKey, let service = jira.service else { return }
        JiraSettings.projectKey = key
        boards = []
        Task {
            boards = (try? await service.listBoards(projectKey: key)) ?? []
            selectBoard(JiraBoardOption.preferred(in: boards, current: boardId)?.id)
        }
    }

    private func selectBoard(_ id: Int?) {
        boardId = id
        JiraSettings.boardId = id
        jira.reload()
    }

    private func row<Content: View>(_ title: String, _ caption: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            label(title, caption)
            Spacer()
            content()
        }
    }

    private func label(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.medium)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
