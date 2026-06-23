import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var currentPage: SidebarPage = .home

    var body: some View {
        if vm.needsPermission {
            PermissionView()
        } else {
            mainContent
        }
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

            case .displays:
                DisplaysView()

            case .settings:
                SettingsView()

            case .about:
                AboutView()
            }
        }
        .navigationSplitViewStyle(.balanced)
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

// MARK: - Toolbar Row

struct ToolbarRow: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 12) {
            // Top row: scan path + actions
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    TextField("Scan path", text: $vm.scanPath)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                )

                Button {
                    Task { await vm.scan() }
                } label: {
                    HStack(spacing: 6) {
                        if vm.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text("Scan").fontWeight(.semibold)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(vm.isScanning)
                .opacity(vm.isScanning ? 0.7 : 1)

                Spacer()

                HStack(spacing: 8) {
                    Button { vm.selectAll() } label: {
                        Label("All", systemImage: "checkmark.circle")
                            .font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(vm.filteredArtifacts.isEmpty)
                    .opacity(vm.filteredArtifacts.isEmpty ? 0.5 : 1)

                    Button { vm.deselectAll() } label: {
                        Label("None", systemImage: "circle")
                            .font(.caption).fontWeight(.medium)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(.ultraThinMaterial))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(vm.selectedArtifacts.isEmpty)
                    .opacity(vm.selectedArtifacts.isEmpty ? 0.5 : 1)

                    Button {
                        vm.requestClean()
                    } label: {
                        HStack(spacing: 6) {
                            if vm.isCleaning {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "trash.fill")
                            }
                            Text("Clean \(formatBytes(vm.selectedSize))")
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(Color(red: 0.82, green: 0.30, blue: 0.42).gradient))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(!vm.canClean)
                    .opacity(vm.canClean ? 1 : 0.5)
                }
            }

            // Search bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField("Filter artifacts...", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
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

// MARK: - Status Bar

struct StatusBar: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.isScanning || vm.isCleaning
                      ? Color(red: 0.85, green: 0.52, blue: 0.25)
                      : Color(red: 0.40, green: 0.70, blue: 0.55))
                .frame(width: 7, height: 7)
                .shadow(color: (vm.isScanning || vm.isCleaning
                                ? Color(red: 0.85, green: 0.52, blue: 0.25)
                                : Color(red: 0.40, green: 0.70, blue: 0.55)).opacity(0.5),
                        radius: 3)

            Text(vm.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if !vm.selectedArtifacts.isEmpty {
                Text("\(vm.selectedArtifacts.count) selected — \(formatBytes(vm.selectedSize))")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(red: 0.40, green: 0.35, blue: 0.70))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
    }
}
