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
    var color: Color { [Color(jiraHex: 0x337ea9), Color(jiraHex: 0x9065b0), Color.gray][rawValue] }
}

struct JiraMenuBarSection: View {
    @ObservedObject var jira: JiraViewModel
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            JiraSprintHeader(sprint: jira.menu.sprint)
            if let error = jira.menuError {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
            } else if jira.menu.rows.isEmpty {
                Text(jira.menuUpdatedAt == nil ? "Loading…" : "Nothing open this month 🎉")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(JiraTaskGroup.allCases) { group($0) }
                    }
                }
                .frame(maxHeight: jiraListMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .task { await jira.refreshMenu() }
    }

    @ViewBuilder
    private func group(_ group: JiraTaskGroup) -> some View {
        let items = jira.menu.rows.filter { $0.group == group }
        if !items.isEmpty || group == .todo {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(group.color)
                    Text("\(items.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                ForEach(items) { JiraTaskRowView(row: $0, open: open) }
                if items.isEmpty {
                    Text("No tasks").font(.system(size: 12)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let updatedAt = jira.menuUpdatedAt {
                Text("Updated \(updatedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Jira") { open("") }
            Button { Task { await jira.refreshMenu() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
        .controlSize(.small)
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
                Circle().fill(row.group.color).frame(width: 7, height: 7)
                Text(row.id).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: jiraKeyColumnWidth, alignment: .leading)
                if row.isBug { Image(systemName: "ladybug.fill").font(.system(size: 10)).foregroundStyle(.red) }
                Text(row.summary).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let app = row.app { JiraAppTag(app: app) }
                if let points = row.points {
                    Text(points).font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .frame(minWidth: 18).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
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
                Capsule().fill(Color.green.opacity(0.18))
                Capsule().fill(LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}

private struct JiraSprintHeader: View {
    let sprint: JiraSprintStats

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "checklist").foregroundStyle(.blue.gradient)
                Text(sprint.name.isEmpty ? "No active sprint" : sprint.name).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let daysLeft = sprint.daysLeft {
                    Text(daysLeft > 0 ? "\(daysLeft) days left" : "Ends today")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(daysLeft <= 2 ? 0.2 : 0), in: Capsule())
                        .foregroundStyle(daysLeft <= 2 ? Color.orange : .secondary)
                }
            }
            if sprint.monthTasks > 0 {
                JiraProgressBar(fraction: Double(sprint.monthDone) / Double(sprint.monthTasks))
                HStack(spacing: 12) {
                    Label("\(sprint.monthTasks) tasks", systemImage: "square.stack.3d.up.fill").foregroundStyle(.green)
                    Label("\(sprint.monthPoints) \(sprint.pointLabel)", systemImage: "bolt.fill").foregroundStyle(.blue)
                    Label("\(Date().formatted(.dateTime.month(.abbreviated))): \(sprint.monthDone) done",
                          systemImage: "calendar").foregroundStyle(.purple)
                }
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
            }
        }
    }
}
