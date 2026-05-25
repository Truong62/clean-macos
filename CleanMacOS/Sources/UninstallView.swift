import SwiftUI
import AppKit

@MainActor
final class UninstallViewModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var searchText = ""
    @Published var selectedApp: InstalledApp?
    @Published var leftovers: [Artifact] = []
    @Published var selectedLeftovers: Set<Artifact.ID> = []
    @Published var isLoadingApps = false
    @Published var isScanning = false
    @Published var isUninstalling = false
    @Published var statusMessage = ""
    @Published var showConfirmation = false

    private let service = UninstallerService()
    private let cleaner = CleanerService()

    var filteredApps: [InstalledApp] {
        guard !searchText.isEmpty else { return apps }
        let q = searchText.lowercased()
        return apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    var totalSize: Int64 { leftovers.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 {
        leftovers.filter { selectedLeftovers.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    var canUninstall: Bool { !selectedLeftovers.isEmpty && !isUninstalling && !isScanning }

    func loadApps() async {
        isLoadingApps = true
        let found = await Task.detached { [service] in service.installedApps() }.value
        apps = found
        isLoadingApps = false
        statusMessage = "\(found.count) apps"
    }

    func select(_ app: InstalledApp) async {
        selectedApp = app
        isScanning = true
        leftovers = []
        selectedLeftovers = []
        statusMessage = "Scanning \(app.name)..."

        let found = await Task.detached { [service] in service.leftovers(for: app) }.value
        leftovers = found
        selectedLeftovers = Set(found.map(\.id)) // default: select everything for a complete uninstall
        isScanning = false
        statusMessage = "\(found.count) items — \(formatBytes(totalSize))"
    }

    func uninstall() async {
        guard let app = selectedApp else { return }
        let paths = leftovers.filter { selectedLeftovers.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }

        isUninstalling = true
        statusMessage = "Moving \(paths.count) items to Trash..."

        let result = await Task.detached { [cleaner] in cleaner.moveToTrash(paths) }.value

        isUninstalling = false
        if result.failCount > 0 {
            statusMessage = "Removed \(result.okCount) items (\(result.freedStr)), \(result.failCount) failed (may need admin)"
        } else {
            statusMessage = "Uninstalled \(app.name) — \(result.freedStr) moved to Trash"
        }

        // Refresh the app list (the app should be gone) and clear the detail pane.
        selectedApp = nil
        leftovers = []
        selectedLeftovers = []
        await loadApps()
    }

    func toggle(_ artifact: Artifact) {
        if selectedLeftovers.contains(artifact.id) {
            selectedLeftovers.remove(artifact.id)
        } else {
            selectedLeftovers.insert(artifact.id)
        }
    }
}

struct UninstallView: View {
    @StateObject private var vm = UninstallViewModel()

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detail
                .frame(minWidth: 360, maxWidth: .infinity)
        }
        .task { if vm.apps.isEmpty { await vm.loadApps() } }
        .alert("Uninstall \(vm.selectedApp?.name ?? "app")?", isPresented: $vm.showConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                Task { await vm.uninstall() }
            }
        } message: {
            Text("Move \(vm.selectedLeftovers.count) item(s) — \(formatBytes(vm.selectedSize)) — to the Trash. You can restore them from the Trash if needed.")
        }
    }

    // MARK: - App list

    private var appList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.caption)
                TextField("Search apps...", text: $vm.searchText)
                    .textFieldStyle(.plain)
                Button {
                    Task { await vm.loadApps() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh app list")
            }
            .padding(10)
            .background(.bar)

            Divider()

            if vm.isLoadingApps {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else {
                List(vm.filteredApps, selection: Binding(
                    get: { vm.selectedApp?.id },
                    set: { id in
                        if let app = vm.apps.first(where: { $0.id == id }) {
                            Task { await vm.select(app) }
                        }
                    }
                )) { app in
                    AppRow(app: app)
                        .tag(app.id)
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let app = vm.selectedApp {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    AppIcon(path: app.path, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.headline)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        vm.showConfirmation = true
                    } label: {
                        HStack(spacing: 5) {
                            if vm.isUninstalling {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "trash.fill")
                            }
                            Text("Uninstall (\(formatBytes(vm.selectedSize)))").fontWeight(.medium)
                        }
                        .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!vm.canUninstall)
                }
                .padding(16)

                Divider()

                if vm.isScanning {
                    Spacer()
                    ProgressView("Finding leftover files...").controlSize(.small)
                    Spacer()
                } else {
                    List {
                        ForEach(vm.leftovers) { item in
                            LeftoverRow(
                                item: item,
                                isOn: vm.selectedLeftovers.contains(item.id),
                                toggle: { vm.toggle(item) }
                            )
                        }
                    }
                }

                Divider()
                HStack {
                    Circle().fill(vm.isScanning || vm.isUninstalling ? .orange : .green).frame(width: 6, height: 6)
                    Text(vm.statusMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(vm.selectedLeftovers.count) of \(vm.leftovers.count) selected")
                        .font(.caption).foregroundStyle(.blue)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(.bar)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "trash.square")
                    .font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("Select an app to uninstall")
                    .font(.title3).fontWeight(.semibold)
                Text("Clean macOS finds every file the app left behind.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

// MARK: - Rows

private struct AppRow: View {
    let app: InstalledApp
    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.path, size: 24)
            Text(app.name).lineLimit(1)
            Spacer()
        }
    }
}

private struct LeftoverRow: View {
    let item: Artifact
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) { }
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.description).fontWeight(.medium)
                Text(item.path)
                    .font(.caption2).fontDesign(.monospaced)
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .help(item.path)
            }
            Spacer()
            Text(item.sizeHuman)
                .font(.callout).fontDesign(.rounded).fontWeight(.semibold)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}

// MARK: - App icon

private struct AppIcon: View {
    let path: String
    let size: CGFloat
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
    }
}
