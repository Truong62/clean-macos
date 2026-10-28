import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var jira: JiraViewModel
    @EnvironmentObject var updater: UpdaterViewModel
    @State private var currentPage: SidebarPage = .home

    var body: some View {
        Group {
            if vm.needsPermission {
                PermissionView()
            } else {
                mainContent
            }
        }
        .overlay { UpdateModal(updater: updater) }
    }

    private var mainContent: some View {
        NavigationSplitView {
            SidebarView(currentPage: $currentPage)
        } detail: {
            switch currentPage {
            case .home:
                HomeView(navigate: { currentPage = $0 })

            case .largeFiles:
                LargeFilesView()

            case .cleanDisk:
                CleanDiskView()

            case .uninstall:
                UninstallView()

            case .clipboard:
                ClipboardHistoryView()

            case .jira:
                JiraView(openSettings: { currentPage = .settings })

            case .displays:
                DisplaysView()

            case .screenRecord:
                ScreenRecordView()

            case .ram:
                RAMView()

            case .portsJobs:
                PortsJobsView()

            case .devTools:
                DevToolsView()

            case .settings:
                SettingsView()

            case .about:
                AboutView(navigate: { currentPage = $0 })
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: jira.openRequestCount) { _, _ in currentPage = .jira }
        .alert("Confirm Clean", isPresented: $vm.showCleanConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clean", role: .destructive) {
                Task { await vm.clean() }
            }
        } message: {
            Text(vm.cleanConfirmationMessage)
        }
    }
}

// MARK: - Category Chip

struct CategoryChip: View {
    let label: String
    let icon: String
    let count: Int
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.3) : Color.primary.opacity(0.08))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Group {
                    if isSelected {
                        Capsule().fill(LinearGradient(colors: [color.opacity(0.85), color.opacity(0.55)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                    }
                }
            )
            .foregroundStyle(isSelected ? .white : .secondary)
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(isSelected ? 0.25 : 0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isSelected ? 0.10 : 0.04), radius: isSelected ? 6 : 3, y: 2)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
