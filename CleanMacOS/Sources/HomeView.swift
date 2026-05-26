import SwiftUI

struct HomeView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var clipboard: ClipboardViewModel
    let navigate: (SidebarPage) -> Void

    @State private var shownCleanable: Double = 0

    private var hasResults: Bool { !vm.artifacts.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                statsRow
                featureCards
                breakdownCard
                systemInfo
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 18) {
            if let info = vm.diskInfo {
                DiskRing(usedPercent: info.usedPercent,
                         freeText: "\(info.freeStr) free",
                         color: ringColor(info.usedPercent))
            } else {
                ProgressView()
                    .frame(width: 184, height: 184)
            }

            if hasResults {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.purple)
                    CountingBytes(value: shownCleanable)
                        .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                    Text("ready to clean")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Scan your disk to find junk")
                    .font(.title3).fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            Button {
                navigate(.cleanDisk)
                if !hasResults { Task { await vm.scan() } }
            } label: {
                HStack(spacing: 6) {
                    if vm.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: hasResults ? "trash.fill" : "magnifyingglass")
                    }
                    Text(hasResults ? "Review & Clean" : "Scan & Clean Disk")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.purple)
            .disabled(vm.isScanning)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { shownCleanable = Double(vm.totalCleanableSize) }
        }
        .onChange(of: vm.totalCleanableSize) { _, new in
            withAnimation(.easeOut(duration: 0.8)) { shownCleanable = Double(new) }
        }
    }

    private func ringColor(_ usedPercent: Double) -> Color {
        if usedPercent > 90 { return .red }
        if usedPercent > 75 { return .orange }
        return .green
    }

    // MARK: - Stats row

    private var statsRow: some View {
        HStack(spacing: 10) {
            StatCard(title: "Total", value: vm.diskInfo?.totalStr ?? "—", icon: "internaldrive.fill", color: .blue)
            StatCard(title: "Used", value: vm.diskInfo?.usedStr ?? "—", icon: "chart.pie.fill", color: .orange)
            StatCard(title: "Free", value: vm.diskInfo?.freeStr ?? "—", icon: "leaf.fill", color: .green)
            StatCard(title: "Cleanable", value: hasResults ? formatBytes(vm.totalCleanableSize) : "—", icon: "sparkles", color: .purple)
            StatCard(title: "Items", value: hasResults ? "\(vm.artifacts.count)" : "—", icon: "doc.on.doc.fill", color: .cyan)
        }
    }

    // MARK: - Feature cards

    private var featureCards: some View {
        HStack(spacing: 12) {
            FeatureCard(icon: "doc.text.magnifyingglass", title: "Large Files",
                        subtitle: "Find big files", color: .orange, index: 0) { navigate(.largeFiles) }
            FeatureCard(icon: "trash.fill", title: "Uninstall Apps",
                        subtitle: "Remove apps + leftovers", color: .red, index: 1) { navigate(.uninstall) }
            FeatureCard(icon: "doc.on.clipboard.fill", title: "Clipboard",
                        subtitle: "\(clipboard.items.count) items", color: .indigo, index: 2) { navigate(.clipboard) }
        }
    }

    // MARK: - Cleanable breakdown

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CLEANABLE BY CATEGORY")
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.tertiary).tracking(1)

            if hasResults {
                ForEach(vm.categoryCounts, id: \.0) { cat, count, size in
                    HStack(spacing: 10) {
                        Image(systemName: cat.icon)
                            .foregroundStyle(cat.color)
                            .frame(width: 22)
                        Text(cat.displayName)
                            .font(.callout)
                        Spacer()
                        Text("\(count) items")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(formatBytes(size))
                            .font(.callout).fontWeight(.medium)
                            .foregroundStyle(cat.color)
                            .frame(width: 84, alignment: .trailing)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Run a scan to see what's cleanable on your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - System info

    @ViewBuilder
    private var systemInfo: some View {
        if let info = vm.diskInfo {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(info.hostname)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !vm.snapshots.isEmpty {
                    Label("\(vm.snapshots.count) snapshots", systemImage: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text("\(info.osVersion) • \(info.arch)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Disk usage ring (animated fill)

private struct DiskRing: View {
    let usedPercent: Double   // 0...100
    let freeText: String
    let color: Color
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary.opacity(0.4), lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(Int(usedPercent.rounded()))%")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                Text("USED")
                    .font(.caption2).foregroundStyle(.tertiary).tracking(1)
                Text(freeText)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(width: 184, height: 184)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                progress = CGFloat(min(max(usedPercent / 100, 0), 1))
            }
        }
    }
}

// MARK: - Count-up bytes label

private struct CountingBytes: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View {
        Text(formatBytes(Int64(max(0, value))))
    }
}

// MARK: - Feature card (subtle hover, gentle entrance — no scale/jump)

private struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let index: Int
    let action: () -> Void

    @State private var hovered = false
    @State private var appeared = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(hovered ? color.opacity(0.45) : color.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: hovered ? .black.opacity(0.10) : .clear, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.22)) { hovered = h }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.08 * Double(index))) { appeared = true }
        }
    }
}
