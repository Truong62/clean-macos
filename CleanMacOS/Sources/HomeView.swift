import SwiftUI

struct HomeView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var clipboard: ClipboardViewModel
    let navigate: (SidebarPage) -> Void

    private var hasResults: Bool { !vm.artifacts.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                featureCards
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var hero: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(.purple.gradient)
                if hasResults {
                    Text("\(formatBytes(vm.totalCleanableSize)) ready to clean")
                        .font(.title).fontWeight(.bold).fontDesign(.rounded)
                } else {
                    Text("Scan your disk to find junk")
                        .font(.title2).fontWeight(.semibold)
                }
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
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.purple)
            .disabled(vm.isScanning)

            if let info = vm.diskInfo {
                DiskUsageBar(info: info, cleanableSize: vm.totalCleanableSize)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var featureCards: some View {
        HStack(spacing: 12) {
            FeatureCard(icon: "doc.text.magnifyingglass", title: "Large Files",
                        subtitle: "Find big files", color: .orange) { navigate(.largeFiles) }
            FeatureCard(icon: "trash.fill", title: "Uninstall Apps",
                        subtitle: "Remove apps + leftovers", color: .red) { navigate(.uninstall) }
            FeatureCard(icon: "doc.on.clipboard.fill", title: "Clipboard",
                        subtitle: "\(clipboard.items.count) items", color: .indigo) { navigate(.clipboard) }
        }
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void
    @State private var hovered = false

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
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(hovered ? color.opacity(0.5) : color.opacity(0.15), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
