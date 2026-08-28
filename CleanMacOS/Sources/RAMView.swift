import SwiftUI

@MainActor
final class RAMViewModel: ObservableObject {
    @Published var processes: [RunningProcess] = []
    @Published var memoryUsage: RAMUsage = .empty
    @Published var filter: RAMProcessFilter = .all
    @Published var searchText = ""
    @Published var selectedPID: pid_t?
    @Published var isPaused = false
    @Published var isRefreshing = false
    @Published var isTerminating = false
    @Published var statusMessage = ""
    @Published var pendingTerminationMode: ProcessTerminationMode?
    @Published var showTerminationConfirmation = false

    private let service: ProcessService
    private var refreshTask: Task<Void, Never>?

    init(service: ProcessService = ProcessService()) {
        self.service = service
    }

    var filteredProcesses: [RunningProcess] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return processes.filter { process in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .apps:
                matchesFilter = process.kind == .app
            case .background:
                matchesFilter = process.kind != .app
            }
            let matchesSearch = query.isEmpty
                || process.name.lowercased().contains(query)
                || process.path.lowercased().contains(query)
            return matchesFilter && matchesSearch
        }
    }

    var selectedProcess: RunningProcess? {
        guard let selectedPID else { return nil }
        return processes.first { $0.pid == selectedPID }
    }

    var selectedRefusalReason: String? {
        guard let selectedProcess else { return "Select a process to manage it." }
        return service.refusalReason(for: selectedProcess)
    }

    var confirmationTitle: String {
        guard let mode = pendingTerminationMode, let process = selectedProcess else { return "Confirm" }
        return "\(mode.label) \(process.name)?"
    }

    var confirmationMessage: String {
        guard let mode = pendingTerminationMode, let process = selectedProcess else { return "" }
        let warning = process.user == "root" ? " Warning: this process is owned by root." : ""
        return "\(mode.label) \(process.name) (PID \(process.pid))?\(warning)"
    }

    func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if !isPaused { await refresh() }
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let listed = await service.list()
        let usage = service.memoryUsage()
        processes = listed
        memoryUsage = usage
        isRefreshing = false
        if listed.isEmpty {
            statusMessage = "No processes found. /bin/ps may be unavailable."
        } else if statusMessage.hasPrefix("No processes found") {
            statusMessage = ""
        }
        if let selectedPID, !listed.contains(where: { $0.pid == selectedPID }) {
            self.selectedPID = nil
        }
    }

    func requestTermination(_ mode: ProcessTerminationMode) {
        guard selectedProcess != nil, selectedRefusalReason == nil else { return }
        pendingTerminationMode = mode
        showTerminationConfirmation = true
    }

    func confirmTermination() async {
        guard let process = selectedProcess, let mode = pendingTerminationMode else { return }
        isTerminating = true
        defer {
            isTerminating = false
            pendingTerminationMode = nil
        }
        do {
            let outcome = try await service.terminate(process, mode: mode)
            statusMessage = outcome.message
        } catch {
            statusMessage = error.localizedDescription
        }
        await refresh()
    }
}

struct RAMView: View {
    @StateObject private var vm = RAMViewModel()
    @State private var sortOrder = [KeyPathComparator(\RunningProcess.memoryBytes, order: .reverse)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                memoryCard
                controls
                processTable
                    .frame(minHeight: 420)
                    .glassCard(cornerRadius: 20)
                actionBar
                if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { vm.startRefreshing() }
        .onDisappear { vm.stopRefreshing() }
        .alert(vm.confirmationTitle, isPresented: $vm.showTerminationConfirmation) {
            Button("Cancel", role: .cancel) { vm.pendingTerminationMode = nil }
            Button(vm.pendingTerminationMode?.label ?? "Quit", role: .destructive) {
                Task { await vm.confirmTermination() }
            }
        } message: {
            Text(vm.confirmationMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("RAM")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer()
            Text("\(vm.processes.count) processes")
                .font(.callout)
                .fontDesign(.rounded)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if vm.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await vm.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(8)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(vm.isRefreshing)
            .help("Refresh processes")
        }
    }

    private var memoryCard: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("MEMORY USED")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .tracking(1)
                Text("\(formatBytes(Int64(clamping: vm.memoryUsage.usedBytes))) / \(formatBytes(Int64(clamping: vm.memoryUsage.totalBytes)))")
                    .font(.title3)
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text("MEMORY PRESSURE")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .tracking(1)
                HStack(spacing: 7) {
                    Circle()
                        .fill(pressureColor)
                        .frame(width: 9, height: 9)
                    Text("\(vm.memoryUsage.pressure.rawValue) · \(vm.memoryUsage.pressurePercent, specifier: "%.0f")%")
                        .font(.title3)
                        .fontDesign(.rounded)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding(18)
        .glassCard(cornerRadius: 20)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $vm.filter) {
                ForEach(RAMProcessFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 270)
            .pointerCursor()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search name or path", text: $vm.searchText)
                    .textFieldStyle(.plain)
                if !vm.searchText.isEmpty {
                    Button { vm.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            Toggle("Pause", isOn: $vm.isPaused)
                .toggleStyle(.switch)
                .pointerCursor()
                .help(vm.isPaused ? "Resume automatic refresh" : "Pause automatic refresh")
        }
    }

    private var processTable: some View {
        Table(vm.filteredProcesses.sorted(using: sortOrder), selection: $vm.selectedPID, sortOrder: $sortOrder) {
            TableColumn("Name", value: \RunningProcess.name) { process in
                HStack(spacing: 8) {
                    Image(systemName: process.kind.systemImage)
                        .foregroundStyle(kindColor(process.kind))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(process.name)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            if process.isSystem {
                                Text(process.user == "root" ? "ROOT" : "SYSTEM")
                                    .font(.system(size: 8, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.red.opacity(0.15))
                                    .foregroundStyle(.red)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        Text(process.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .help(process.path)
            }
            .width(min: 210, ideal: 320)

            TableColumn("PID", value: \RunningProcess.pid) { process in
                Text("\(process.pid)")
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
            }
            .width(min: 55, ideal: 65)

            TableColumn("CPU %", value: \RunningProcess.cpuPercent) { process in
                Text(process.cpuPercent, format: .number.precision(.fractionLength(1)))
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Memory", value: \RunningProcess.memoryBytes) { process in
                Text(formatBytes(Int64(clamping: process.memoryBytes)))
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 95)

            TableColumn("User", value: \RunningProcess.user) { process in
                Text(process.user)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Kind", value: \RunningProcess.kindLabel) { process in
                Text(process.kind.label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(kindColor(process.kind).opacity(0.12))
                    .foregroundStyle(kindColor(process.kind))
                    .clipShape(Capsule())
            }
            .width(min: 90, ideal: 110)
        }
        .scrollContentBackground(.hidden)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let process = vm.selectedProcess {
                Text("\(process.name) · PID \(process.pid)")
                    .font(.callout)
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let refusal = vm.selectedRefusalReason {
                    Label(refusal, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(process.user == "root" ? .red : .orange)
                        .lineLimit(2)
                }
            } else {
                Text("Select a process to quit it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { vm.requestTermination(.graceful) }
                .buttonStyle(.bordered)
                .pointerCursor()
                .disabled(vm.selectedRefusalReason != nil || vm.isTerminating)
            Button("Force Quit", role: .destructive) { vm.requestTermination(.force) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .pointerCursor()
                .disabled(vm.selectedRefusalReason != nil || vm.isTerminating)
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    private var pressureColor: Color {
        switch vm.memoryUsage.pressure {
        case .low: .green
        case .moderate: .orange
        case .high: .red
        }
    }

    private func kindColor(_ kind: RunningProcessKind) -> Color {
        switch kind {
        case .app: .blue
        case .backgroundApp: .purple
        case .daemon: .orange
        }
    }
}
