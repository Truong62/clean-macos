import SwiftUI

private let jiraAppColors: [String: UInt32] = [
    "SEO": 0x00af96, "Blog": 0xd4679f, "AEO": 0x7988ed, "APC": 0xdb703b, "Speed": 0x73a434,
    "Team": 0x7e95ad, "Feed": 0xb68c00, "Ads": 0xde6674, "Pixels": 0x00a7cb, "Canva": 0xa878db,
]
private let jiraListMaxHeight: CGFloat = 320
private let jiraKeyColumnWidth: CGFloat = 60

private extension Color {
    init(jiraHex hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

private extension JiraTaskGroup {
    var color: Color { [Color(jiraHex: 0x337ea9), Color.orange, Color.gray][rawValue] }
}

private extension JiraTaskRow {
    var statusColor: Color {
        if isDone { return .green }
        switch status {
        case JiraMenuSnapshot.doingStatus: return Color(jiraHex: 0x337ea9)
        case JiraMenuSnapshot.todoStatus: return .gray
        default: return Color(jiraHex: 0x9065b0)
        }
    }
}

struct JiraMenuBarSection: View {
    @ObservedObject var jira: JiraViewModel
    let open: (String) -> Void

    private var refreshHelp: String {
        jira.menuUpdatedAt.map { "Refresh · updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Refresh"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                JiraSprintTitle(sprint: jira.menu.sprint)
                Spacer()
                MenuIconButton(systemImage: "arrow.up.forward.app", help: "Open Jira") { open("") }
                MenuIconButton(systemImage: "arrow.clockwise", help: refreshHelp) { Task { await jira.refreshMenu() } }
            }
            JiraMonthProgress(sprint: jira.menu.sprint)
            if let error = jira.menuError {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if jira.menu.rows.isEmpty {
                Text(jira.menuUpdatedAt == nil ? "Loading…" : "Nothing open this month 🎉")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .vertical) {
                    taskList
                    ScrollView { taskList }
                }
                .frame(maxHeight: jiraListMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .task { await jira.refreshMenu() }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(JiraTaskGroup.allCases) { group($0) }
        }
    }

    @ViewBuilder
    private func group(_ group: JiraTaskGroup) -> some View {
        let items = jira.menu.rows.filter { $0.group == group }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(group.title.uppercased()) \(items.count)")
                    .font(.system(size: 9.5, weight: .semibold)).tracking(0.5).foregroundStyle(group.color)
                    .padding(.horizontal, 6).padding(.bottom, 2)
                ForEach(items) { JiraTaskRowView(row: $0, open: open) }
            }
        }
    }
}

private struct JiraAppTag: View {
    let app: String

    var body: some View {
        let color = Color(jiraHex: jiraAppColors[app] ?? 0x8a8a8a)
        Text(app)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct JiraTaskRowView: View {
    let row: JiraTaskRow
    let open: (String) -> Void
    @State private var isHovered = false

    var body: some View {
        Button { open(row.id) } label: {
            HStack(spacing: 8) {
                Circle().fill(row.statusColor).frame(width: 7, height: 7)
                Text(row.id).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: jiraKeyColumnWidth, alignment: .leading)
                if row.isBug { Image(systemName: "ladybug.fill").font(.system(size: 10)).foregroundStyle(.red) }
                Text(row.summary).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let app = row.app { JiraAppTag(app: app) }
                if let points = row.points {
                    Text(points).font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 18).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(row.status)
    }
}

private struct JiraProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.orange.opacity(0.18))
                Capsule().fill(LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

private struct JiraSprintTitle: View {
    let sprint: JiraSprintStats

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checklist").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange.gradient)
            Text(sprint.name.isEmpty ? "No active sprint" : sprint.name).font(.system(size: 12.5, weight: .semibold))
            if let daysLeft = sprint.daysLeft {
                Text(daysLeft > 0 ? "· \(daysLeft)d left" : "· ends today")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(daysLeft <= 2 ? Color.orange : .secondary)
            }
        }
    }
}

private struct JiraMonthProgress: View {
    let sprint: JiraSprintStats

    var body: some View {
        if sprint.monthTasks > 0 {
            HStack(spacing: 8) {
                JiraProgressBar(fraction: Double(sprint.monthDone) / Double(sprint.monthTasks))
                Text("\(sprint.monthDone)/\(sprint.monthTasks) done · \(sprint.monthPoints) \(sprint.pointLabel) · \(Date().formatted(.dateTime.month(.abbreviated)))")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}
