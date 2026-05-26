import SwiftUI
import AppKit

// Soft pastel blob gradient — the Sense signature (pink → peach → lavender → mint).
private let pastelGradient = LinearGradient(
    colors: [
        Color(red: 0.98, green: 0.80, blue: 0.86),
        Color(red: 0.99, green: 0.87, blue: 0.77),
        Color(red: 0.86, green: 0.82, blue: 0.95),
        Color(red: 0.80, green: 0.92, blue: 0.86),
    ],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

// Dark ink that stays legible on the light pastel hero, regardless of system theme.
private let heroInk = Color(red: 0.17, green: 0.15, blue: 0.23)

struct HomeView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var clipboard: ClipboardViewModel
    let navigate: (SidebarPage) -> Void

    @State private var shownCleanable: Double = 0

    private var hasResults: Bool { !vm.artifacts.isEmpty }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good Morning"
        case 12..<18: return "Good Afternoon"
        default: return "Good Evening"
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                greetingCard
                heroCard
                featureCards
                breakdownCard
                systemInfo
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .background(background)
    }

    // Light base with a soft pastel glow pooling at the bottom (like the shot).
    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack {
                Spacer()
                pastelGradient
                    .frame(height: 320)
                    .blur(radius: 90)
                    .opacity(0.35)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Greeting

    private var greetingCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(pastelGradient)
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "sparkles").font(.system(size: 18)).foregroundStyle(.white))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.title2).fontWeight(.bold)
                Text(vm.diskInfo.map { "\($0.hostname) · what can we clean today?" } ?? "Keep your Mac calm and clean")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    // MARK: - Hero featured card (pastel)

    private var heroCard: some View {
        VStack(spacing: 18) {
            if let info = vm.diskInfo {
                DiskRing(usedPercent: info.usedPercent,
                         freeText: "\(info.freeStr) free",
                         arcColor: arcColor(info.usedPercent))
            } else {
                ProgressView().frame(width: 178, height: 178).tint(heroInk)
            }

            if hasResults {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(heroInk)
                    CountingBytes(value: shownCleanable)
                        .font(.title2).fontWeight(.bold).fontDesign(.rounded)
                        .foregroundStyle(heroInk)
                    Text("ready to clean").foregroundStyle(heroInk.opacity(0.6))
                }
            } else {
                Text("Scan your disk to find junk")
                    .font(.title3).fontWeight(.medium)
                    .foregroundStyle(heroInk.opacity(0.7))
            }

            pillCTA
        }
        .padding(.vertical, 34)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
        .background(pastelGradient)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { shownCleanable = Double(vm.totalCleanableSize) }
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
                    ProgressView().controlSize(.small).tint(heroInk)
                } else {
                    Image(systemName: hasResults ? "trash.fill" : "sparkles")
                }
                Text(hasResults ? "Review & Clean" : "Scan & Clean Disk")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 26).padding(.vertical, 13)
            .background(Capsule().fill(.white))
            .foregroundStyle(heroInk)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(vm.isScanning)
        .opacity(vm.isScanning ? 0.7 : 1)
    }

    private func arcColor(_ usedPercent: Double) -> Color {
        if usedPercent > 90 { return Color(red: 0.82, green: 0.30, blue: 0.42) }
        if usedPercent > 75 { return Color(red: 0.85, green: 0.52, blue: 0.25) }
        return Color(red: 0.40, green: 0.35, blue: 0.70)
    }

    // MARK: - Feature cards (pastel thumbnails)

    private var featureCards: some View {
        HStack(spacing: 12) {
            FeatureCard(icon: "doc.text.magnifyingglass", title: "Large Files",
                        description: "Hunt down the biggest files and folders anywhere on your Mac and send the space-hogs to the Trash.",
                        color: .orange, index: 0) { navigate(.largeFiles) }
            FeatureCard(icon: "trash.fill", title: "Uninstall Apps",
                        description: "Remove an app and every leftover it hides — caches, preferences, containers and logs included.",
                        color: .pink, index: 1) { navigate(.uninstall) }
            FeatureCard(icon: "doc.on.clipboard.fill", title: "Clipboard",
                        description: "Everything you copy is kept here — \(clipboard.items.count) saved. Bring back earlier copies with ⌘⇧V.",
                        color: .indigo, index: 2) { navigate(.clipboard) }
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
                        Image(systemName: cat.icon).foregroundStyle(cat.color).frame(width: 22)
                        Text(cat.displayName).font(.callout)
                        Spacer()
                        Text("\(count) items").font(.caption).foregroundStyle(.secondary)
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
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    // MARK: - System info

    @ViewBuilder
    private var systemInfo: some View {
        if let info = vm.diskInfo {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer").font(.caption2).foregroundStyle(.tertiary)
                Text(info.hostname).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !vm.snapshots.isEmpty {
                    Label("\(vm.snapshots.count) snapshots", systemImage: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text("\(info.osVersion) • \(info.arch)").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Disk usage ring (animated fill, styled for the pastel hero)

private struct DiskRing: View {
    let usedPercent: Double
    let freeText: String
    let arcColor: Color
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.55), lineWidth: 13)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(arcColor, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(Int(usedPercent.rounded()))%")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(heroInk)
                Text("USED").font(.caption2).foregroundStyle(heroInk.opacity(0.5)).tracking(1.5)
                Text(freeText).font(.caption).foregroundStyle(heroInk.opacity(0.7)).padding(.top, 2)
            }
        }
        .frame(width: 178, height: 178)
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

// MARK: - Feature card (pastel thumbnail, soft hover)

private struct FeatureCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    let index: Int
    let action: () -> Void

    @State private var hovered = false
    @State private var appeared = false

    private var thumb: LinearGradient {
        LinearGradient(colors: [color.opacity(0.85), color.opacity(0.45)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(thumb)
                    .frame(height: 64)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    )
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(description)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 188, alignment: .leading)
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(hovered ? 0.14 : 0.05),
                    radius: hovered ? 16 : 7, y: hovered ? 7 : 3)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeInOut(duration: 0.25)) { hovered = h }
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovered { NSCursor.pop() } }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.08 * Double(index))) { appeared = true }
        }
    }
}
