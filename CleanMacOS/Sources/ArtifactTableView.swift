import SwiftUI

struct ArtifactTableView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var sortOrder = [KeyPathComparator(\Artifact.size, order: .reverse)]

    var sortedArtifacts: [Artifact] {
        vm.filteredArtifacts.sorted(using: sortOrder)
    }

    var body: some View {
        if vm.artifacts.isEmpty && !vm.isScanning {
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 6) {
                    Text("No Artifacts Found")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("Scan your system to discover cleanable files")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await vm.scan() }
                } label: {
                    Label("Start Scan", systemImage: "magnifyingglass")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else if vm.isScanning {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Scanning filesystem...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            Table(sortedArtifacts, selection: $vm.selectedArtifacts, sortOrder: $sortOrder) {
                TableColumn("") { artifact in
                    Toggle(isOn: Binding(
                        get: { vm.selectedArtifacts.contains(artifact.id) },
                        set: { selected in
                            if selected {
                                vm.selectedArtifacts.insert(artifact.id)
                            } else {
                                vm.selectedArtifacts.remove(artifact.id)
                            }
                        }
                    )) { }
                    .toggleStyle(.checkbox)
                    .disabled(artifact.needsSudo)
                }
                .width(30)

                TableColumn("Name", value: \.name) { artifact in
                    HStack(spacing: 8) {
                        Image(systemName: artifact.category.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(artifact.category.color.gradient)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(artifact.name)
                                    .fontWeight(.medium)
                                if artifact.needsSudo {
                                    Text("ROOT")
                                        .font(.system(size: 8, weight: .bold, design: .rounded))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.red.opacity(0.15))
                                        .foregroundStyle(.red)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            Text(artifact.description)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .width(min: 200, ideal: 280)

                TableColumn("Category", value: \.category.displayName) { artifact in
                    Text(artifact.category.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(artifact.category.color.opacity(0.1))
                        .foregroundStyle(artifact.category.color)
                        .clipShape(Capsule())
                }
                .width(min: 100, ideal: 120)

                TableColumn("Path") { artifact in
                    Text(artifact.path)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(artifact.path)
                }
                .width(min: 150, ideal: 250)

                TableColumn("Size", value: \.size) { artifact in
                    Text(artifact.sizeHuman)
                        .font(.callout)
                        .fontDesign(.rounded)
                        .fontWeight(.semibold)
                        .foregroundStyle(sizeColor(artifact.size))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 70, ideal: 90)
            }
        }
    }

    private func sizeColor(_ size: Int64) -> Color {
        if size > 1_073_741_824 { return .red }
        if size > 104_857_600 { return .orange }
        return .primary
    }
}
