import SwiftUI

struct JiraSettingsForm: View {
    @EnvironmentObject var jira: JiraViewModel
    @AppStorage(JiraSettings.domainKey) private var domain = ""
    @AppStorage(JiraSettings.authKindKey) private var authKind = JiraSettings.AuthKind.server.rawValue
    @AppStorage(JiraSettings.emailKey) private var email = ""
    @AppStorage(JiraSettings.projectKeyKey) private var projectKey = ""
    @AppStorage(JiraSettings.appFieldNameKey) private var appFieldName = ""
    @AppStorage(JiraSettings.roleKey) private var role = JiraSettings.Role.dev.rawValue
    @AppStorage(JiraSettings.menuBarEnabledKey) private var menuBarEnabled = true
    @AppStorage(JiraSettings.notificationsEnabledKey) private var notificationsEnabled = true
    @State private var boardId = JiraSettings.boardId.map(String.init) ?? ""
    @State private var token = ""
    @State private var status = ""
    @State private var isTesting = false

    var body: some View {
        row("Domain", "e.g. https://yourcompany.atlassian.net") {
            TextField("https://", text: $domain).textFieldStyle(.roundedBorder).frame(width: 300)
        }
        row("Authentication", "Server/Data Center token or Cloud email + API token") {
            Picker("", selection: $authKind) {
                Text("Server (PAT)").tag(JiraSettings.AuthKind.server.rawValue)
                Text("Cloud").tag(JiraSettings.AuthKind.cloud.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
        }
        if authKind == JiraSettings.AuthKind.cloud.rawValue {
            row("Email", "Your Atlassian account email") {
                TextField("you@company.com", text: $email).textFieldStyle(.roundedBorder).frame(width: 300)
            }
        }
        row("Token", jira.hasToken ? "Saved in Keychain — type to replace" : "Stored in Keychain") {
            SecureField(jira.hasToken ? "••••••••" : "Token", text: $token).textFieldStyle(.roundedBorder).frame(width: 300)
        }
        row("Project key", "Issues of this project are listed") {
            TextField("FAL", text: $projectKey).textFieldStyle(.roundedBorder).frame(width: 300)
        }
        row("Board ID", "Agile board for columns and sprints (number in the board URL)") {
            TextField("10030", text: $boardId).textFieldStyle(.roundedBorder).frame(width: 300)
        }
        row("App field", "Custom field shown as the app tag (optional)") {
            TextField("Falcon App", text: $appFieldName).textFieldStyle(.roundedBorder).frame(width: 300)
        }
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
                label("Notifications", "Added to a task, new comment on your task, @mention")
            }
            .onChange(of: notificationsEnabled) { _, _ in jira.restartBackgroundWork() }
            Spacer()
            Button("Send Test") { Task { status = await jira.sendTestNotification() } }
                .pointerCursor()
        }
        HStack {
            Button("Save & Test Connection", action: saveAndTest)
                .disabled(isTesting)
                .pointerCursor()
            if isTesting { ProgressView().controlSize(.small) }
            Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func saveAndTest() {
        JiraSettings.domain = domain
        JiraSettings.email = email
        JiraSettings.projectKey = projectKey
        JiraSettings.boardId = Int(boardId.trimmingCharacters(in: .whitespaces))
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
