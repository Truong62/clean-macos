import SwiftUI

struct HomeView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var clipboard: ClipboardViewModel
    let navigate: (SidebarPage) -> Void

    @State private var shownCleanable: Double = 0
    @State private var breathing = false

    private var hasResults: Bool { !vm.artifacts.isEmpty }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                greetingHeader
                heroPanel
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

    // MARK: - Greeting

    private var greetingHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.title2).fontWeight(.bold)
                Text(vm.diskInfo.map { "\($0.hostname) · \(Int($0.usedPercent.rounded()))% full" } ?? "Keep your Mac calm and clean")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Hero panel (dark, breathing glow, orb, pill)

    private var heroPanel: some View {
        ZStack {
            if let info = vm.diskInfo {
                Circle()
                    .fill(ringColor(info.usedPercent).opacity(0.45))
                    .frame(width: 220, height: 220)
                    .blur(radius: 72)
                    .scaleEffect(breathing ? 1.10 : 0.92)
                    .opacity(breathing ? 0.9 : 0.5)
                    .offset(y: -24)
            }

            VStack(spacing: 18) {
                if let info = vm.diskInfo {
                    DiskOrb(usedPercent: info.usedPercent,
                            freeText: "\(info.freeStr) free",
                            color: ringColor(info.usedPercent))
                } else {
                    ProgressView().frame(width: 190, height: 190).tint(.white)
                }

                if hasResults {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.9))
                        CountingBytes(value: shownCleanable)
                            .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                            .foregroundStyle(.white)
                        Text("ready to clean").foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    Text("Scan your disk to find junk")
                        .font(.title3).fontWeight(.medium)
                        .foregroundStyle(.white.opacity(0.7))
                }

                pillCTA
            }
            .padding(.vertical, 36)
            .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.09, green: 0.08, blue: 0.17))
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { shownCleanable = Double(vm.totalCleanableSize) }
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { breathing = true }
        }
        .onChange(of: vm.totalCleanableSize) { _, new in
            withAnimation(.easeOut(duration: 0.8)) { shownCleanable = Double(new) }
        }
    }

    private var pillCTA: some View {
        Button {
            navigate(.cleanDisk)
            if !hasResults { Task { await vm.scan() } }
        } label: {
            HStack(spacing: 8) {
                if vm.isScanning {
                    ProgressView().controlSize(.small).tint(.black)
                } else {
                    Image(systemName: hasResults ? "trash.fill" : "sparkles")
                }
                Text(hasResults ? "Review & Clean" : "Scan & Clean Disk")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(Capsule().fill(.white))
            .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .disabled(vm.isScanning)
        .opacity(vm.isScanning ? 0.7 : 1)
    }

    private func ringColor(_ usedPercent: Double) -> Color {
        if usedPercent > 90 { return .pink }
        if usedPercent > 75 { return .orange }
        return .mint
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
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

// MARK: - Disk usage orb (animated fill on dark)

private struct DiskOrb: View {
    let usedPercent: Double   // 0...100
    let freeText: String
    let color: Color
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.7), radius: 8)
            VStack(spacing: 2) {
                Text("\(Int(usedPercent.rounded()))%")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("USED")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5)).tracking(1.5)
                Text(freeText)
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 2)
            }
        }
        .frame(width: 190, height: 190)
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) {
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

// MARK: - Feature card (soft, calm — subtle shadow hover, no scale)

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
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.15))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovered ? 0.12 : 0.04),
                    radius: hovered ? 14 : 5, y: hovered ? 6 : 2)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.25)) { hovered = h }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.08 * Double(index))) { appeared = true }
        }
    }
}
