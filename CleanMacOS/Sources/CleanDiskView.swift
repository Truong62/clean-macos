import AppKit
import SwiftUI

struct CleanDiskView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 16) {
            CleanDiskHero()
            if vm.isScanning {
                ScanningCard()
            } else if vm.artifacts.isEmpty {
                ScanIntroCard()
            } else {
                CleanDiskFilterBar()
                ArtifactTableView()
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .homeCard()
                if !vm.snapshots.isEmpty {
                    SnapshotSection()
                }
            }
            CleanDiskActionBar()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $vm.showResults) {
            CleanResultsView()
                .environmentObject(vm)
        }
    }
}

struct CleanDiskHero: View {
    @EnvironmentObject var vm: AppViewModel

    static let colors = [Color(red: 0.07, green: 0.55, blue: 0.70), Color(red: 0.20, green: 0.42, blue: 0.90),
                         Color(red: 0.42, green: 0.36, blue: 0.95)]

    private var isCompact: Bool { !vm.artifacts.isEmpty && !vm.isScanning }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
                Text("CLEAN DISK")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.7))
                Text(title)
                    .font(.system(size: isCompact ? 26 : 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    scanButton
                    ScanPathPill()
                }
                .padding(.top, 4)
                if isCompact {
                    CleanableBar(segments: vm.categoryCounts)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
            if let info = vm.diskInfo {
                DiskGauge(usedPercent: info.usedPercent, freeText: "\(info.freeStr) free")
                    .scaleEffect(isCompact ? 0.72 : 1)
                    .frame(width: isCompact ? 121 : 168, height: isCompact ? 121 : 168)
            }
        }
        .padding(isCompact ? 20 : 26)
        .animation(.snappy, value: isCompact)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: Self.colors[1].opacity(0.3), radius: 20, y: 10)
    }

    private var title: String {
        if vm.isScanning { return "Scanning your Mac…" }
        if vm.artifacts.isEmpty { return "Find what's filling your disk" }
        return "\(formatBytes(vm.totalCleanableSize)) ready to clean"
    }

    private var subtitle: String {
        if vm.isScanning { return "Looking for build output, caches, logs and leftovers. This usually takes under a minute." }
        if vm.artifacts.isEmpty { return "Scan for developer junk, caches and logs you can safely remove." }
        let top = vm.categoryCounts.prefix(3).map { "\($0.0.displayName) \(formatBytes($0.2))" }.joined(separator: " · ")
        return "\(vm.artifacts.count) items — \(top)"
    }

    private var scanButton: some View {
        Button {
            Task { await vm.scan() }
        } label: {
            HStack(spacing: 8) {
                if vm.isScanning {
                    ProgressView().controlSize(.small).tint(Self.colors[1])
                } else {
                    Image(systemName: vm.artifacts.isEmpty ? "sparkle.magnifyingglass" : "arrow.clockwise")
                }
                Text(vm.isScanning ? "Scanning…" : vm.artifacts.isEmpty ? "Start Scan" : "Scan Again")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 11)
            .foregroundStyle(Self.colors[1])
            .background(Capsule().fill(.white))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(vm.isScanning || vm.isCleaning)
    }

    private var background: some View {
        ZStack {
            LinearGradient(colors: Self.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            SoftGlow(color: .white.opacity(0.25)).frame(width: 460, height: 460).offset(x: 280, y: -150)
            SoftGlow(color: Color(red: 0.35, green: 0.95, blue: 0.85).opacity(0.35)).frame(width: 420, height: 420).offset(x: -320, y: 150)
        }
    }
}

struct ScanPathPill: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
            Text((vm.scanPath as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Change…", action: chooseFolder)
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .underline()
                .pointerCursor()
                .disabled(vm.isScanning)
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.white.opacity(0.16), in: Capsule())
        .help("Developer folders like node_modules are searched under this folder. Caches and logs are always checked.")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: vm.scanPath)
        panel.prompt = "Scan Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.scanPath = url.path
    }
}

struct ScanIntroCard: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WHAT GETS CHECKED")
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(ArtifactCategory.allCases) { category in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: category.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(category.color.gradient, in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.displayName).font(.callout.weight(.semibold))
                            Text(category.examples).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            Label("Nothing is removed until you pick items and press Clean. Personal data is flagged and never selected for you.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .homeCard()
    }
}

struct ScanningCard: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(vm.scanStartedAt ?? context.date))
            let categories = ArtifactCategory.allCases
            let current = categories[(elapsed / 3) % categories.count]
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(current.color.opacity(0.15), lineWidth: 6)
                    ProgressView().controlSize(.large)
                }
                .frame(width: 84, height: 84)
                VStack(spacing: 6) {
                    Text("Checking \(current.displayName.lowercased())…")
                        .font(.title3.weight(.semibold))
                        .contentTransition(.opacity)
                    Text(current.examples)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("\(elapsed)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .animation(.easeInOut, value: current)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .homeCard()
    }
}

struct CleanDiskFilterBar: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            CategoryChip(label: "All", icon: "square.grid.2x2", count: vm.artifacts.count, color: .blue,
                         isSelected: vm.selectedCategory == nil) { vm.selectedCategory = nil }
            ForEach(vm.categoryCounts, id: \.0) { category, count, _ in
                CategoryChip(label: category.displayName, icon: category.icon, count: count, color: category.color,
                             isSelected: vm.selectedCategory == category) { vm.selectedCategory = category }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Filter by name or path", text: $vm.searchText)
                    .textFieldStyle(.plain)
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: 260)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

struct CleanDiskActionBar: View {
    @EnvironmentObject var vm: AppViewModel

    private var selection: [Artifact] {
        AppViewModel.flattened(vm.artifacts).filter { vm.selectedArtifacts.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 12) {
            if vm.selectedArtifacts.isEmpty {
                Circle()
                    .fill(vm.isScanning || vm.isCleaning ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(vm.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(vm.selectedArtifacts.count) selected · \(formatBytes(vm.selectedSize))")
                        .font(.headline)
                        .contentTransition(.numericText())
                    if !flags.isEmpty {
                        Text(flags.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if !vm.artifacts.isEmpty {
                Button("Select All") { vm.selectAll() }
                    .disabled(vm.filteredArtifacts.isEmpty || vm.isCleaning)
                    .help("Selects everything shown except personal data and admin-only items")
                    .pointerCursor()
                Button("Select None") { vm.deselectAll() }
                    .disabled(vm.selectedArtifacts.isEmpty || vm.isCleaning)
                    .pointerCursor()
            }
            Button {
                vm.requestClean()
            } label: {
                HStack(spacing: 8) {
                    if vm.isCleaning {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "trash.fill")
                    }
                    Text(vm.isCleaning ? "Cleaning…" : "Clean \(formatBytes(vm.selectedSize))")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Capsule().fill(LinearGradient(colors: [Color(red: 0.93, green: 0.36, blue: 0.45), Color(red: 0.80, green: 0.25, blue: 0.55)],
                                                          startPoint: .leading, endPoint: .trailing)))
                .shadow(color: Color(red: 0.9, green: 0.3, blue: 0.5).opacity(vm.canClean ? 0.35 : 0), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!vm.canClean)
            .opacity(vm.canClean ? 1 : 0.45)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .homeCard(cornerRadius: 18)
        .animation(.snappy, value: vm.selectedArtifacts.isEmpty)
    }

    private var flags: [String] {
        var flags: [String] = []
        if selection.contains(where: \.isPersonalData) { flags.append("Includes personal data") }
        if selection.contains(where: \.needsSudo) { flags.append("Asks for your admin password") }
        if selection.contains(where: { $0.reclaim.isCommand }) { flags.append("Runs a cleanup command") }
        return flags
    }
}
