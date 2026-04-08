import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue.gradient)
                Text("Clean macOS")
                    .font(.headline)
                Spacer()
                Text(monitor.osVersion)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Stats
            VStack(spacing: 12) {
                MenuStatRow(
                    icon: "cpu",
                    color: .blue,
                    title: "CPU",
                    value: String(format: "%.1f%%", monitor.cpuUsage),
                    percent: monitor.cpuUsage / 100
                )

                MenuStatRow(
                    icon: "memorychip",
                    color: .orange,
                    title: "Memory",
                    value: "\(monitor.memUsedStr) / \(monitor.memTotalStr)",
                    percent: monitor.memPercent / 100
                )

                MenuStatRow(
                    icon: "internaldrive.fill",
                    color: .green,
                    title: "Disk",
                    value: "\(monitor.diskUsedStr) / \(monitor.diskTotalStr)",
                    percent: monitor.diskPercent / 100
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Info rows
            VStack(spacing: 8) {
                MenuInfoRow(label: "CPU", value: monitor.cpuName)
                MenuInfoRow(label: "Free Disk", value: monitor.diskFreeStr)
                MenuInfoRow(label: "Uptime", value: monitor.uptime)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Actions
            VStack(spacing: 4) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                } label: {
                    HStack {
                        Image(systemName: "macwindow")
                        Text("Open Clean macOS")
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                Divider()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text("Quit")
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
    }
}

// MARK: - Menu Stat Row

struct MenuStatRow: View {
    let icon: String
    let color: Color
    let title: String
    let value: String
    let percent: Double

    private var barColor: Color {
        if percent > 0.9 { return .red }
        if percent > 0.75 { return .orange }
        return color
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color.gradient)
                    .font(.caption)
                    .frame(width: 16)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(value)
                    .font(.caption)
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
                    .foregroundStyle(barColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.15))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor.gradient)
                        .frame(width: geo.size.width * min(percent, 1))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Menu Info Row

struct MenuInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontDesign(.rounded)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
