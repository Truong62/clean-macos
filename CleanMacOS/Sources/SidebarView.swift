import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        List(selection: $vm.selectedCategory) {
            Section {
                NavigationLink(value: Optional<ArtifactCategory>.none) {
                    Label {
                        HStack {
                            Text("All")
                            Spacer()
                            if !vm.artifacts.isEmpty {
                                Text("\(vm.artifacts.count)")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary)
                                    .clipShape(Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: "square.grid.2x2")
                    }
                }
                .tag(Optional<ArtifactCategory>.none)
            }

            if !vm.categoryCounts.isEmpty {
                Section("Categories") {
                    ForEach(vm.categoryCounts, id: \.0) { cat, count, size in
                        NavigationLink(value: Optional(cat)) {
                            Label {
                                HStack {
                                    Text(cat.displayName)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text("\(count)")
                                            .font(.caption2)
                                            .fontWeight(.medium)
                                        Text(formatBytes(size))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: cat.icon)
                                    .foregroundStyle(cat.color)
                            }
                        }
                        .tag(Optional(cat))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        .searchable(text: $vm.searchText, prompt: "Filter artifacts")
    }
}
