import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 14) {
            // Stat cards
            HStack(spacing: 12) {
                StatCard(title: "Total", value: vm.diskInfo?.totalStr ?? "—", icon: "internaldrive.fill", color: .blue)
                StatCard(title: "Used", value: vm.diskInfo?.usedStr ?? "—", icon: "chart.pie.fill", color: .orange)
                StatCard(title: "Free", value: vm.diskInfo?.freeStr ?? "—", icon: "leaf.fill", color: .green)
                StatCard(title: "Cleanable", value: vm.artifacts.isEmpty ? "—" : formatBytes(vm.totalCleanableSize), icon: "sparkles", color: .purple)
                StatCard(title: "Items", value: vm.artifacts.isEmpty ? "—" : "\(vm.artifacts.count)", icon: "doc.on.doc.fill", color: .cyan)
                if !vm.snapshots.isEmpty {
                    StatCard(title: "Snapshots", value: "\(vm.snapshots.count)", icon: "clock.arrow.circlepath", color: .indigo)
                }
            }

            // Disk usage bar
            if let info = vm.diskInfo {
                DiskUsageBar(info: info, cleanableSize: vm.totalCleanableSize)
            }
        }
        .padding(16)
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [color.opacity(0.85), color.opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }
}

// MARK: - Disk Usage Bar

struct DiskUsageBar: View {
    let info: DiskInfo
    let cleanableSize: Int64

    private var usedFraction: Double {
        Double(info.used) / Double(info.total)
    }

    private var cleanableFraction: Double {
        Double(cleanableSize) / Double(info.total)
    }

    private var barColor: Color {
        if info.usedPercent > 90 { return .red }
        if info.usedPercent > 75 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DISK USAGE")
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.tertiary).tracking(1)

            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(info.hostname)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                Spacer()
                Text("\(String(format: "%.1f", info.usedPercent))% used")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(barColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.quaternary.opacity(0.5))

                    RoundedRectangle(cornerRadius: 5)
                        .fill(barColor.gradient)
                        .frame(width: geo.size.width * usedFraction)

                    if cleanableSize > 0 {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(.purple.opacity(0.5))
                            .frame(width: geo.size.width * cleanableFraction)
                            .offset(x: geo.size.width * (usedFraction - cleanableFraction))
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 16) {
                Label("Used", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(barColor)
                Label("Free", systemImage: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                if cleanableSize > 0 {
                    Label("Cleanable", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Spacer()
                Text("\(info.osVersion) • \(info.arch)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
