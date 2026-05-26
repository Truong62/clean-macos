import SwiftUI

struct HomeView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var clipboard: ClipboardViewModel
    let navigate: (SidebarPage) -> Void

    @State private var shownCleanable: Double = 0
    @State private var animateGradient = false

    private var hasResults: Bool { !vm.artifacts.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero
                featureCards
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
                    .frame(width: 180, height: 180)
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
        .background(animatedGradient)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { shownCleanable = Double(vm.totalCleanableSize) }
        }
        .onChange(of: vm.totalCleanableSize) { _, new in
            withAnimation(.easeOut(duration: 0.8)) { shownCleanable = Double(new) }
        }
    }

    private var animatedGradient: some View {
        LinearGradient(
            colors: [.purple.opacity(0.30), .blue.opacity(0.22), .teal.opacity(0.25)],
            startPoint: animateGradient ? .topLeading : .bottomLeading,
            endPoint: animateGradient ? .bottomTrailing : .topTrailing
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                animateGradient = true
            }
        }
    }

    private func ringColor(_ usedPercent: Double) -> Color {
        if usedPercent > 90 { return .red }
        if usedPercent > 75 { return .orange }
        return .green
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
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
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

// MARK: - Feature card (hover lift + staggered entrance)

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
                    .strokeBorder(hovered ? color.opacity(0.6) : color.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: hovered ? color.opacity(0.35) : .clear, radius: 12, y: 6)
            .scaleEffect(hovered ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { hovered = h }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 16)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4).delay(0.08 * Double(index))) { appeared = true }
        }
    }
}
