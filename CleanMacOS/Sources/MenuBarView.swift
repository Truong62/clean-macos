import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var jira: JiraViewModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(JiraSettings.menuBarEnabledKey) private var jiraMenuBarEnabled = true

    private var showsJira: Bool { jira.isConfigured && jiraMenuBarEnabled }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showsJira {
                JiraMenuBarSection(jira: jira) { key in
                    openWindow(id: "main")
                    DispatchQueue.main.async { jira.openFromOutside(issueKey: key) }
                }
                Divider()
            }
            systemStats
        }
        .frame(width: showsJira ? 380 : 300)
        .onAppear { monitor.popoverDidOpen() }
        .onDisappear { monitor.popoverDidClose() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.orange.gradient)
            Text("Clean macOS").font(.system(size: 13, weight: .semibold))
            Spacer()
            MenuIconButton(systemImage: "macwindow", help: "Open Clean macOS") {
                openWindow(id: "main")
                DispatchQueue.main.async { MainWindowController.show() }
            }
            MenuIconButton(systemImage: "power", help: "Quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .help(monitor.osVersion)
    }

    private var systemStats: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                MenuStatColumn(title: "CPU", value: String(format: "%.0f%%", monitor.cpuUsage),
                               percent: monitor.cpuUsage / 100, color: .blue)
                MenuStatColumn(title: "RAM", value: monitor.memUsedStr, percent: monitor.memPercent / 100, color: .orange)
                MenuStatColumn(title: "Disk", value: monitor.diskUsedStr, percent: monitor.diskPercent / 100, color: .green)
            }
            Text("\(monitor.cpuName) · \(monitor.diskFreeStr) free · up \(monitor.uptime)")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct MenuIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 22)
                .background(isHovered ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

struct MenuStatColumn: View {
    let title: String
    let value: String
    let percent: Double
    let color: Color

    private var barColor: Color {
        if percent > 0.9 { return .red }
        if percent > 0.75 { return .orange }
        return color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(barColor)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.15))
                    Capsule().fill(barColor.gradient).frame(width: geo.size.width * min(max(percent, 0), 1))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
    }
}
