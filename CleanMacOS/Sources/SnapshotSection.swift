import SwiftUI

struct SnapshotSection: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(vm.snapshots) { snapshot in
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.indigo.gradient)
                            .font(.system(size: 14))
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.date)
                                .font(.callout)
                                .fontDesign(.monospaced)
                                .fontWeight(.medium)
                            Text(snapshot.name)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if !snapshot.size.isEmpty {
                            Text(snapshot.size)
                                .font(.caption)
                                .fontDesign(.rounded)
                                .fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial)
                                .clipShape(Capsule())
                        }

                        Button(role: .destructive) {
                            Task { await vm.deleteSnapshot(snapshot) }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete snapshot (requires sudo)")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    if snapshot.id != vm.snapshots.last?.id {
                        Divider().padding(.leading, 48).opacity(0.5)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.indigo.gradient)
                Text("Time Machine Snapshots")
                    .font(.headline)
                Text("\(vm.snapshots.count)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .fontDesign(.rounded)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.indigo.opacity(0.12))
                    .foregroundStyle(.indigo)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
