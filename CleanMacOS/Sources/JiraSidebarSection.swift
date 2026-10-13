import SwiftUI

struct JiraSidebarSection: View {
    @EnvironmentObject var jira: JiraViewModel

    private static let listStyles: [String: (icon: String, color: Color)] = [
        "sprint": ("timer", .indigo),
        "doing": ("smallcircle.filled.circle", .blue),
        "all": ("list.bullet", .gray),
        "done": ("checkmark.circle", .green),
    ]
    private static let viewIcons = ["table": "tablecells", "board": "rectangle.split.3x1"]

    var body: some View {
        if jira.isConfigured && !jira.nav.lists.isEmpty {
            VStack(spacing: 2) {
                ForEach(jira.nav.lists, id: \.id) { item in
                    let style = Self.listStyles[item.id] ?? ("list.bullet", .gray)
                    SidebarSubRow(label: item.label, count: item.count, icon: style.icon, color: style.color, isSelected: jira.nav.list == item.id) {
                        jira.selectNav(list: item.id)
                    }
                }
                Picker("View", selection: Binding(get: { jira.nav.view }, set: { jira.selectNav(view: $0) })) {
                    ForEach(jira.nav.views, id: \.id) { item in
                        Label(item.label, systemImage: Self.viewIcons[item.id] ?? "square.grid.2x2").tag(item.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.top, 6)
                .padding(.horizontal, 4)
            }
            .padding(.leading, 18)
            .padding(.bottom, 4)
        }
    }
}

struct SidebarSubRow: View {
    let label: String
    var count: Int? = nil
    let icon: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(label)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(isSelected ? 0.1 : (isHovered ? 0.05 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
    }
}
