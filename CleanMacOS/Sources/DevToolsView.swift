import SwiftUI

struct DevToolsView: View {
    @StateObject private var vm = DevToolsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            controls
            table
                .frame(minHeight: 200, maxHeight: .infinity)
                .glassCard(cornerRadius: 20)
            detailPanel
            if !vm.statusMessage.isEmpty {
                Text(vm.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await vm.load() }
        .onChange(of: vm.tab) { _, _ in vm.selectedID = nil; vm.measureVisibleSizes() }
        .onChange(of: vm.showsDependencies) { _, _ in vm.measureVisibleSizes() }
        .alert("Uninstall \(vm.pendingRemoval?.name ?? "")?", isPresented: vm.isConfirmingRemoval, presenting: vm.pendingRemoval) { tool in
            Button("Cancel", role: .cancel) { }
            Button("Uninstall", role: .destructive) { Task { await vm.remove(tool) } }
        } message: { tool in
            Text(vm.removalMessage(tool))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Dev Tools")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer()
            Text(summary)
                .font(.callout)
                .fontDesign(.rounded)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if vm.isLoading || vm.isWorking || vm.isCheckingUpdates { ProgressView().controlSize(.small) }
            if !vm.updatableTools.isEmpty {
                Button {
                    Task { await vm.updateAll() }
                } label: {
                    Label("Update All (\(vm.updatableTools.count))", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .pointerCursor()
                .disabled(vm.isWorking || vm.isLoading)
                .help(vm.updatableTools.map(\.name).joined(separator: ", "))
            }
            Button {
                Task { await vm.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(8)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Refresh")
            .disabled(vm.isLoading)
        }
    }

    private var summary: String {
        let count = vm.visibleTools.count
        let size = vm.visibleTotalSize
        return size > 0 ? "\(count) items · \(formatBytes(size))" : "\(count) items"
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $vm.tab) {
                ForEach(DevToolKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 360)
            .pointerCursor()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Search name, version or source", text: $vm.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if vm.tab == .homebrew {
                Toggle("Show dependencies", isOn: $vm.showsDependencies)
                    .toggleStyle(.switch)
                    .pointerCursor()
                    .help("Include formulae installed only because another formula needs them")
            }
        }
    }

    private var table: some View {
        Table(vm.visibleTools, selection: $vm.selectedID) {
            TableColumn("Name") { tool in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.name).fontWeight(.medium).lineLimit(1)
                    Text(tool.summary.isEmpty ? tool.path : tool.summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(tool.path)
            }
            .width(min: 200, ideal: 320)
            TableColumn("Version") { tool in
                HStack(spacing: 6) {
                    Text(tool.version).fontDesign(.rounded).lineLimit(1)
                    if tool.note != nil {
                        Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange).help(tool.note ?? "")
                    }
                }
            }
            .width(min: 80, ideal: 110)
            TableColumn("Source") { tool in
                badge(tool.source, color: .blue)
            }
            .width(min: 100, ideal: 170)
            TableColumn("Size") { tool in
                Text(vm.sizes[tool.id].map(formatBytes) ?? "…")
                    .fontDesign(.rounded)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Status") { tool in
                if tool.isActive {
                    badge("In use", color: .green)
                } else if tool.isDependency {
                    badge("Dependency", color: .gray)
                }
            }
            .width(min: 80, ideal: 100)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: DevTool.ID.self) { ids in
            if let tool = vm.tools.first(where: { ids.contains($0.id) }) {
                Button("Reveal in Finder") { vm.reveal(tool) }
                Button("Copy Path") { vm.copyPath(tool) }
                if tool.homepage != nil { Button("Open Homepage") { vm.openHomepage(tool) } }
                Divider()
                if tool.updateCommand != nil {
                    Button("Update") { Task { await vm.update(tool) } }.disabled(vm.isWorking)
                }
                Button("Uninstall…") { vm.pendingRemoval = tool }.disabled(!tool.canRemove)
            }
        }
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let tool = vm.selected {
                detail(tool)
            } else {
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }

    private var hint: String {
        switch vm.tab {
        case .runtime: "Every Node.js, Python, Ruby, Go, Java, Rust, Bun and Deno you installed — from nvm, fnm, pyenv, asdf, mise, Homebrew or an installer. “In use” is the one your Terminal runs."
        case .homebrew: "Formulae and casks installed with Homebrew. Dependencies are hidden unless you turn them on."
        case .package: "Command-line tools installed globally with npm, bun, go install or cargo install."
        }
    }

    @ViewBuilder private func detail(_ tool: DevTool) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(tool.name) \(tool.version)").font(.headline).lineLimit(1)
            if tool.isActive { badge("In use", color: .green) }
            Spacer()
            Button("Reveal") { vm.reveal(tool) }.pointerCursor()
            Button("Copy Path") { vm.copyPath(tool) }.pointerCursor()
            if tool.homepage != nil { Button("Homepage") { vm.openHomepage(tool) }.pointerCursor() }
            if tool.updateCommand != nil {
                Button("Update") { Task { await vm.update(tool) } }
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()
                    .disabled(vm.isWorking)
            }
            Button("Uninstall", role: .destructive) { vm.pendingRemoval = tool }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .pointerCursor()
                .disabled(!tool.canRemove || vm.isWorking)
                .help(tool.canRemove ? "" : vm.removalMessage(tool))
        }
        if !tool.summary.isEmpty { detailRow("About", tool.summary) }
        detailRow("Source", tool.source)
        detailRow("Location", tool.path, monospaced: true)
        detailRow("Size", vm.sizes[tool.id].map(formatBytes) ?? "Measuring…")
        if let note = tool.note { detailRow("Update", note) }
        if tool.isDependency { detailRow("Installed", "As a dependency of another formula") }
        if case .unavailable(let reason) = tool.removal { detailRow("Uninstall", reason) }
    }

    private func detailRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
