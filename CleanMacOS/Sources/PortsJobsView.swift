import SwiftUI

struct PortsJobsView: View {
    @StateObject private var vm = PortsJobsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            controls
            Group {
                switch vm.tab {
                case .ports: portsTable
                case .jobs: jobsTable
                }
            }
            .frame(minHeight: 360)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { vm.startRefreshing() }
        .onDisappear { vm.stopRefreshing() }
        .alert(vm.confirmation?.title ?? "", isPresented: vm.isConfirming) {
            Button("Cancel", role: .cancel) { }
            Button(vm.confirmation?.actionLabel ?? "OK", role: .destructive) { Task { await vm.confirm() } }
        } message: {
            Text(vm.confirmation?.message ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Ports & Jobs")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer()
            Text(vm.tab == .ports ? "\(vm.ports.count) listening" : "\(vm.filteredJobs.count) jobs")
                .font(.callout)
                .fontDesign(.rounded)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            if vm.isRefreshing || vm.isWorking { ProgressView().controlSize(.small) }
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
            .help("Refresh")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $vm.tab) {
                ForEach(PortsJobsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 240)
            .pointerCursor()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(vm.tab == .ports ? "Search port, process or PID" : "Search name or command", text: $vm.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))

            if vm.tab == .jobs {
                Toggle("Show system", isOn: $vm.showsSystemJobs)
                    .toggleStyle(.switch)
                    .pointerCursor()
                    .help("Include /Library LaunchAgents and LaunchDaemons")
            }
        }
    }

    private var portsTable: some View {
        Table(vm.filteredPorts, selection: $vm.selectedPortID) {
            TableColumn("Port") { port in
                Text(verbatim: "\(port.port)").fontDesign(.rounded).fontWeight(.bold)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Process") { port in
                Text(port.command).fontWeight(.medium).lineLimit(1).help(port.command)
            }
            .width(min: 140, ideal: 220)
            TableColumn("PID") { port in
                Text(verbatim: "\(port.pid)").fontDesign(.rounded)
            }
            .width(min: 55, ideal: 65)
            TableColumn("Address") { port in
                Text(port.addresses.map { $0 == "*" ? "All interfaces" : $0 }.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 140)
            TableColumn("Scope") { port in
                badge(port.scopeLabel, color: port.isLocalOnly ? .green : .orange)
            }
            .width(min: 80, ideal: 90)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: ListeningPort.ID.self) { _ in } primaryAction: { ids in
            guard let port = vm.ports.first(where: { ids.contains($0.id) }) else { return }
            vm.openInBrowser(port)
        }
    }

    private var jobsTable: some View {
        Table(vm.filteredJobs, selection: $vm.selectedJobID) {
            TableColumn("Job") { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.label).fontWeight(.medium).lineLimit(1)
                    Text(job.command)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .help(job.command)
            }
            .width(min: 220, ideal: 340)
            TableColumn("Schedule") { job in
                Text(job.schedule).lineLimit(1).help(job.schedule)
            }
            .width(min: 100, ideal: 140)
            TableColumn("Status") { job in
                Text(job.statusLabel).foregroundStyle(statusColor(job)).fontWeight(.medium).lineLimit(1)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Source") { job in
                badge(job.source.label, color: job.source.isManageable ? .blue : .gray)
            }
            .width(min: 90, ideal: 120)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var actionBar: some View {
        HStack(spacing: 10) {
            switch vm.tab {
            case .ports: portActions
            case .jobs: jobActions
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    @ViewBuilder private var portActions: some View {
        if let port = vm.selectedPort {
            Text("\(port.command) · port \(port.port)").font(.callout).fontWeight(.semibold).lineLimit(1)
            Spacer()
            Button("Open in Browser") { vm.openInBrowser(port) }.pointerCursor()
            Button("Quit") { vm.confirmation = .quitPort(port, .graceful) }
                .pointerCursor()
                .disabled(vm.isWorking)
            Button("Force Quit", role: .destructive) { vm.confirmation = .quitPort(port, .force) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .pointerCursor()
                .disabled(vm.isWorking)
        } else {
            Text("Select a port to open it or stop the process holding it. Only your own processes are listed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    @ViewBuilder private var jobActions: some View {
        if let job = vm.selectedJob {
            Text(job.label).font(.callout).fontWeight(.semibold).lineLimit(1)
            Spacer()
            if let log = job.logPath { Button("Open Log") { vm.openLog(log) }.pointerCursor() }
            if let plist = job.plistPath { Button("Reveal") { vm.reveal(plist) }.pointerCursor() }
            if job.source.isManageable {
                Button("Run Now") { Task { await vm.runNow(job) } }
                    .pointerCursor()
                    .disabled(vm.isWorking || !job.isLoaded)
                if job.isLoaded {
                    Button("Turn Off", role: .destructive) { vm.confirmation = .turnOff(job) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .pointerCursor()
                        .disabled(vm.isWorking)
                } else {
                    Button("Turn On") { Task { await vm.turnOn(job) } }
                        .buttonStyle(.borderedProminent)
                        .pointerCursor()
                        .disabled(vm.isWorking)
                }
            }
        } else {
            Text("Select a job to run, turn off or inspect it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func statusColor(_ job: ScheduledJob) -> Color {
        if job.isRunning { return .green }
        if job.statusLabel.hasPrefix("Failed") { return .red }
        return job.isLoaded ? .primary : .secondary
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
