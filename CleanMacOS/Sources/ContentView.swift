import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardView()

            ToolbarRow()

            Divider().opacity(0.5)

            ArtifactTableView()

            if !vm.snapshots.isEmpty {
                SnapshotSection()
            }

            StatusBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Toolbar Row

struct ToolbarRow: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 10) {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )

                Button {
                    Task { await vm.scan() }
                } label: {
                    HStack(spacing: 5) {
                        if vm.isScanning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text("Scan")
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(vm.isScanning)

                Spacer()

                HStack(spacing: 6) {
                    Button { vm.selectAll() } label: {
                        Label("All", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.filteredArtifacts.isEmpty)

                    Button { vm.deselectAll() } label: {
                        Label("None", systemImage: "circle")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vm.selectedArtifacts.isEmpty)

                    Button {
                        Task { await vm.clean() }
                    } label: {
                        HStack(spacing: 5) {
                            if vm.isCleaning {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "trash.fill")
                            }
                            Text("Clean \(formatBytes(vm.selectedSize))")
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)
                    .disabled(!vm.canClean)
                }
            }

            // Bottom row: category chips + search
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        CategoryChip(
                            label: "All",
                            icon: "square.grid.2x2",
                            count: vm.artifacts.count,
                            color: .primary,
                            isSelected: vm.selectedCategory == nil
                        ) {
                            vm.selectedCategory = nil
                        }

                        ForEach(vm.categoryCounts, id: \.0) { cat, count, _ in
                            CategoryChip(
                                label: cat.displayName,
                                icon: cat.icon,
                                count: count,
                                color: cat.color,
                                isSelected: vm.selectedCategory == cat
                            ) {
                                vm.selectedCategory = cat
                            }
                        }
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                    TextField("Filter...", text: $vm.searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary, lineWidth: 1)
                )
                .frame(width: 200)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.25) : Color.gray.opacity(0.2))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? color.opacity(0.8) : Color.clear)
            .foregroundStyle(isSelected ? .white : .secondary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? Color.clear : Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.isScanning || vm.isCleaning ? .orange : .green)
                .frame(width: 6, height: 6)

            Text(vm.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if !vm.selectedArtifacts.isEmpty {
                Text("\(vm.selectedArtifacts.count) selected — \(formatBytes(vm.selectedSize))")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
