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

// Dark ink that stays legible on the light pastel accents, regardless of system theme.
private let heroInk = Color(red: 0.17, green: 0.15, blue: 0.23)

struct UninstallView: View {
    @StateObject private var vm = UninstallViewModel()

    var body: some View {
        HSplitView {
            appList
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detail
                .frame(minWidth: 360, maxWidth: .infinity)
        }
        .background(background)
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

    // Light base with a soft pastel glow pooling at the bottom (matches Home).
    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack {
                Spacer()
                appPastelGradient
                    .frame(height: 320)
                    .blur(radius: 90)
                    .opacity(0.30)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - App list

    private var appList: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.callout)
                TextField("Search apps...", text: $vm.searchText)
                    .textFieldStyle(.plain)
                Button {
                    Task { await vm.loadApps() }
                } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Refresh app list")
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .glassCard(cornerRadius: 14)
            .padding(.horizontal, 12)
            .padding(.top, 12)

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
                .scrollContentBackground(.hidden)
            }
        }
        .background(.clear)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let app = vm.selectedApp {
            VStack(spacing: 14) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(appPastelGradient)
                        .frame(width: 60, height: 60)
                        .overlay(AppIcon(path: app.path, size: 44))
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title3).fontWeight(.bold)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    uninstallButton
                }
                .padding(16)
                .glassCard()
                .padding(.horizontal, 16)
                .padding(.top, 16)

                if vm.isScanning {
                    Spacer()
                    ProgressView("Finding leftover files...").controlSize(.small)
                    Spacer()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("LEFTOVER FILES")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.tertiary).tracking(1)
                            .padding(.horizontal, 4)

                        List {
                            ForEach(vm.leftovers) { item in
                                LeftoverRow(
                                    item: item,
                                    isOn: vm.selectedLeftovers.contains(item.id),
                                    toggle: { vm.toggle(item) }
                                )
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                    .padding(.horizontal, 16)
                }

                statusBar
            }
        } else {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(appPastelGradient)
                    .frame(width: 92, height: 92)
                    .overlay(
                        Image(systemName: "trash.square")
                            .font(.system(size: 40))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
                VStack(spacing: 6) {
                    Text("Select an app to uninstall")
                        .font(.title3).fontWeight(.semibold)
                    Text("Clean macOS finds every file the app left behind.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var uninstallButton: some View {
        Button {
            vm.showConfirmation = true
        } label: {
            HStack(spacing: 6) {
                if vm.isUninstalling {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "trash.fill")
                }
                Text("Uninstall (\(formatBytes(vm.selectedSize)))").fontWeight(.semibold)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Capsule().fill(Color(red: 0.82, green: 0.30, blue: 0.42)))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!vm.canUninstall)
        .opacity(vm.canUninstall ? 1 : 0.45)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(vm.isScanning || vm.isUninstalling ? .orange : .green).frame(width: 7, height: 7)
            Text(vm.statusMessage).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(vm.selectedLeftovers.count) of \(vm.leftovers.count) selected")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(heroInk.opacity(0.7))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .glassCard(cornerRadius: 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

// MARK: - Rows

private struct AppRow: View {
    let app: InstalledApp
    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 7)
                .fill(.white.opacity(0.5))
                .frame(width: 30, height: 30)
                .overlay(AppIcon(path: app.path, size: 22))
            Text(app.name).lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct LeftoverRow: View {
    let item: Artifact
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
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
                .foregroundStyle(heroInk.opacity(0.75))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(isOn ? 0.45 : 0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        .opacity(isOn ? 1 : 0.7)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .pointerCursor()
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
