import AppKit
import SwiftUI

@MainActor
final class DevToolsViewModel: ObservableObject {
    @Published var tab: DevToolKind = .runtime
    @Published private(set) var tools: [DevTool] = []
    @Published private(set) var sizes: [DevTool.ID: Int64] = [:]
    @Published var searchText = ""
    @Published var showsDependencies = false
    @Published var selectedID: DevTool.ID?
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var isCheckingUpdates = false
    @Published var statusMessage = ""
    @Published var pendingRemoval: DevTool?

    private let service: DevToolsService
    private var sizeTask: Task<Void, Never>?

    init(service: DevToolsService = DevToolsService()) {
        self.service = service
    }

    var visibleTools: [DevTool] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return tools.filter { tool in
            tool.kind == tab
                && (tab != .homebrew || showsDependencies || !tool.isDependency)
                && (query.isEmpty || "\(tool.name) \(tool.version) \(tool.source) \(tool.summary)".localizedCaseInsensitiveContains(query))
        }
    }

    var selected: DevTool? { tools.first { $0.id == selectedID } }
    var updatableTools: [DevTool] { visibleTools.filter { $0.updateCommand != nil } }

    var visibleTotalSize: Int64 {
        visibleTools.compactMap { sizes[$0.id] }.reduce(0, +)
    }

    var isConfirmingRemoval: Binding<Bool> {
        Binding(get: { self.pendingRemoval != nil }, set: { if !$0 { self.pendingRemoval = nil } })
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        tools = await service.list()
        isLoading = false
        measureVisibleSizes()
        isCheckingUpdates = true
        tools = await service.checkPackageUpdates(tools)
        isCheckingUpdates = false
    }

    func update(_ tool: DevTool) async {
        isWorking = true
        statusMessage = "Updating \(tool.name)… this can take a few minutes."
        do {
            try await service.update(tool)
            statusMessage = "Updated \(tool.name)."
        } catch {
            statusMessage = "\(tool.name): \(error.localizedDescription)"
        }
        isWorking = false
        sizes[tool.id] = nil
        await load()
    }

    func updateAll() async {
        let pending = updatableTools
        isWorking = true
        var failed: [String] = []
        for (index, tool) in pending.enumerated() {
            statusMessage = "Updating \(tool.name) (\(index + 1) of \(pending.count))…"
            do { try await service.update(tool) } catch { failed.append(tool.name) }
            sizes[tool.id] = nil
        }
        statusMessage = failed.isEmpty
            ? "Updated \(pending.count) item\(pending.count == 1 ? "" : "s")."
            : "Updated \(pending.count - failed.count) of \(pending.count). Failed: \(failed.joined(separator: ", ")) — select one and press Update to see why."
        isWorking = false
        await load()
    }

    func measureVisibleSizes() {
        sizeTask?.cancel()
        let pending = visibleTools.filter { sizes[$0.id] == nil }
        sizeTask = Task { [weak self] in
            for tool in pending {
                guard let self, !Task.isCancelled else { return }
                let size = await self.service.size(of: tool)
                self.sizes[tool.id] = size
            }
        }
    }

    func remove(_ tool: DevTool) async {
        pendingRemoval = nil
        isWorking = true
        do {
            try await service.remove(tool)
            statusMessage = "Removed \(tool.name) \(tool.version)."
            selectedID = nil
        } catch {
            statusMessage = error.localizedDescription
        }
        isWorking = false
        await load()
    }

    func removalMessage(_ tool: DevTool) -> String {
        let warning = tool.isActive ? "This is the version your Terminal uses right now.\n\n" : ""
        switch tool.removal {
        case .trash(let path): return warning + "\(path) is moved to the Trash."
        case .command(let path, let arguments):
            let words = path == "/usr/bin/env" ? Array(arguments.dropFirst()) : [path] + arguments
            let command = ([words.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""] + words.dropFirst()).joined(separator: " ")
            return warning + "Runs: \(command)"
        case .unavailable(let reason): return reason
        }
    }

    func reveal(_ tool: DevTool) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: tool.path)])
    }

    func copyPath(_ tool: DevTool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tool.path, forType: .string)
    }

    func openHomepage(_ tool: DevTool) {
        if let url = tool.homepage { NSWorkspace.shared.open(url) }
    }
}
