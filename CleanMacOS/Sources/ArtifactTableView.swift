import AppKit
import SwiftUI

struct ArtifactTableView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var sortOrder = [KeyPathComparator(\Artifact.size, order: .reverse)]
    @State private var highlighted = Set<Artifact.ID>()

    private var sortedArtifacts: [Artifact] {
        vm.filteredArtifacts.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedArtifacts, children: \.children, selection: $highlighted, sortOrder: $sortOrder) {
            TableColumn("") { artifact in
                Toggle("Select \(artifact.name)", isOn: Binding(
                    get: { vm.selectedArtifacts.contains(artifact.id) },
                    set: { isOn in
                        if isOn { vm.selectedArtifacts.insert(artifact.id) } else { vm.selectedArtifacts.remove(artifact.id) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            .width(28)

            TableColumn("Name", value: \.name) { artifact in
                nameCell(artifact)
            }
            .width(min: 260, ideal: 460)

            TableColumn("Category", value: \.category.displayName) { artifact in
                Text(artifact.category.displayName)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(artifact.category.color.opacity(0.12))
                    .foregroundStyle(artifact.category.color)
                    .clipShape(Capsule())
            }
            .width(min: 90, ideal: 110)

            TableColumn("Size", value: \.size) { artifact in
                Text(artifact.sizeHuman)
                    .font(.callout.weight(.semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(sizeColor(artifact.size))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: Artifact.ID.self) { ids in
            let items = AppViewModel.flattened(vm.artifacts).filter { ids.contains($0.id) }
            if !items.isEmpty { menu(items) }
        } primaryAction: { ids in
            AppViewModel.flattened(vm.artifacts).filter { ids.contains($0.id) }.forEach(vm.toggleSelection)
        }
    }

    @ViewBuilder private func menu(_ items: [Artifact]) -> some View {
        let allSelected = items.allSatisfy { vm.selectedArtifacts.contains($0.id) }
        Button(allSelected ? "Deselect" : "Select") {
            for item in items {
                if allSelected { vm.selectedArtifacts.remove(item.id) } else { vm.selectedArtifacts.insert(item.id) }
            }
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) })
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
        }
    }

    private func nameCell(_ artifact: Artifact) -> some View {
        HStack(spacing: 10) {
            Image(systemName: artifact.category.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(artifact.category.color.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(artifact.name).fontWeight(.medium).lineLimit(1)
                    if artifact.needsSudo { tag("ADMIN", .red, help: "macOS asks for your administrator password to remove this") }
                    if artifact.isPersonalData { tag("PERSONAL", .pink, help: "Your own data — never selected automatically") }
                    if artifact.reclaim.isCommand {
                        Image(systemName: "terminal")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("Reclaimed with \(artifact.reclaim.commandString ?? "a command")")
                    }
                    if let warning = artifact.warning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help(warning)
                    }
                }
                Text((artifact.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(artifact.description.isEmpty ? artifact.path : "\(artifact.description)\n\(artifact.path)")
    }

    private func tag(_ text: String, _ color: Color, help: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help(help)
    }

    private func sizeColor(_ size: Int64) -> Color {
        if size > 1_073_741_824 { return .red }
        if size > 104_857_600 { return .orange }
        return .primary
    }
}
