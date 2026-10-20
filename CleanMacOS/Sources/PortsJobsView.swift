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
                case .loginItems: loginItemsTable
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)
            .glassCard(cornerRadius: 20)
            detailPanel
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
        .onChange(of: vm.selectedPortID) { _, _ in Task { await vm.loadDetails() } }
        .onChange(of: vm.selectedJobID) { _, _ in Task { await vm.loadDetails() } }
        .alert(vm.confirmation?.title ?? "", isPresented: vm.isConfirming, presenting: vm.confirmation) { pending in
            Button("Cancel", role: .cancel) { }
            Button(pending.actionLabel, role: .destructive) { Task { await vm.confirm(pending) } }
        } message: { pending in
            Text(pending.message)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Ports & Jobs")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer()
            Text(countLabel)
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

    private var countLabel: String {
        switch vm.tab {
        case .ports: "\(vm.ports.count) listening"
        case .jobs: "\(vm.filteredJobs.count) jobs"
        case .loginItems: "\(vm.loginItems.filter { $0.isEnabled && !$0.isMissing }.count) open at login"
        }
    }

    private var searchPrompt: String {
        switch vm.tab {
        case .ports: "Search port, process or PID"
        case .jobs: "Search name or command"
        case .loginItems: "Search app"
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $vm.tab) {
                ForEach(PortsJobsTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 360)
            .pointerCursor()

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(searchPrompt, text: $vm.searchText)
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
            if vm.tab == .loginItems {
                Button {
                    Task { await vm.addLoginItem() }
                } label: {
                    Label("Add App…", systemImage: "plus")
                }
                .pointerCursor()
                .disabled(vm.isWorking)
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
        .contextMenu(forSelectionType: ListeningPort.ID.self) { ids in
            if let port = vm.ports.first(where: { ids.contains($0.id) }) {
                Button("Open in Browser") { vm.openInBrowser(port) }
                Button("Copy URL") { copy("http://localhost:\(port.port)") }
                Divider()
                Button("Quit") { vm.confirmation = .quitPort(port, .graceful) }
                Button("Force Quit") { vm.confirmation = .quitPort(port, .force) }
            }
        } primaryAction: { ids in
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
        .contextMenu(forSelectionType: ScheduledJob.ID.self) { ids in
            if let job = vm.jobs.first(where: { ids.contains($0.id) }) { jobMenu(job) }
        }
    }

    private var loginItemsTable: some View {
        Table(vm.filteredLoginItems, selection: $vm.selectedLoginItemID) {
            TableColumn("App") { item in
                HStack(spacing: 10) {
                    appIcon(item).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).fontWeight(.medium).lineLimit(1)
                        Text(item.path ?? "Location unknown")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .opacity(item.isEnabled ? 1 : 0.6)
            }
            .width(min: 220, ideal: 380)
            TableColumn("Status") { item in
                badge(item.statusLabel, color: item.isMissing ? .orange : item.isEnabled ? .green : .gray)
            }
            .width(min: 100, ideal: 130)
            TableColumn("Open at Login") { item in
                loginToggle(item)
            }
            .width(min: 90, ideal: 110)
        }
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: LoginItem.ID.self) { ids in
            if let item = vm.loginItems.first(where: { ids.contains($0.id) }) {
                if !item.isMissing {
                    Button(item.isEnabled ? "Turn Off" : "Turn On") { Task { await vm.setLoginItem(item, enabled: !item.isEnabled) } }
                    if let path = item.path { Button("Reveal in Finder") { vm.reveal(path) } }
                    Divider()
                }
                Button("Remove from List…") { vm.confirmation = .forgetLoginItem(item) }
            }
        }
    }

    private func loginToggle(_ item: LoginItem) -> some View {
        Toggle("Open at Login", isOn: Binding(get: { item.isEnabled },
                                              set: { isOn in Task { await vm.setLoginItem(item, enabled: isOn) } }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(item.isMissing || vm.isWorking)
            .pointerCursor()
    }

    @ViewBuilder private func appIcon(_ item: LoginItem) -> some View {
        if let path = item.path, !item.isMissing {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable()
        } else {
            Image(systemName: "questionmark.app.dashed").resizable().scaledToFit().foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func jobMenu(_ job: ScheduledJob) -> some View {
        if job.source.isManageable {
            Button("Run Now") { Task { await vm.runNow(job) } }.disabled(!job.isLoaded)
            if job.isRunning { Button("Stop") { vm.confirmation = .stopJob(job) } }
            if job.isLoaded {
                Button("Turn Off") { vm.confirmation = .turnOff(job) }
            } else {
                Button("Turn On") { Task { await vm.turnOn(job) } }
            }
            Divider()
        }
        if let log = job.logPaths.first { Button("Open Log") { vm.openLog(log) } }
        if let plist = job.plistPath { Button("Reveal in Finder") { vm.reveal(plist) } }
        Button("Copy Command") { copy(job.command) }
        if job.source.isDeletable {
            Divider()
            Button("Delete…") { vm.confirmation = .deleteJob(job) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch vm.tab {
            case .ports:
                if let port = vm.selectedPort { portDetail(port) } else { hint("Select a port to see details, open it in the browser or stop the process holding it. Right-click a row for actions. Only your own processes are listed.") }
            case .jobs:
                if let job = vm.selectedJob { jobDetail(job) } else { hint("Select a job to see its command, schedule and log. Right-click a row for actions.") }
            case .loginItems:
                if let item = vm.selectedLoginItem { loginItemDetail(item) } else { hint("These apps open automatically when you log in. Turn one off and it stays in this list so you can turn it back on later. Background helpers live under Scheduled Jobs; Clean macOS itself is in Settings › General.") }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private func portDetail(_ port: ListeningPort) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(port.command) · port \(port.port)").font(.headline).lineLimit(1)
            Spacer()
            portButtons(port)
        }
        detailRow("PID", "\(port.pid) · \(port.user)")
        detailRow("Address", port.addresses.map { $0 == "*" ? "All interfaces" : $0 }.joined(separator: ", "))
        if let details = vm.portDetails { processRows(details) }
    }

    @ViewBuilder private func processRows(_ details: ProcessDetails) -> some View {
        if let directory = details.directory {
            detailRow("Folder", (directory as NSString).abbreviatingWithTildeInPath, monospaced: true)
        }
        detailRow("Running for", details.readableElapsed)
        detailRow("Usage", "CPU \(details.cpuPercent.formatted(.number.precision(.fractionLength(1))))% · Memory \(formatBytes(Int64(details.rssKilobytes) * 1_024))")
        if details.parentPID > 1 {
            detailRow("Started by", "\(details.parentName) · PID \(details.parentPID)")
        }
        detailRow("Command", details.arguments, monospaced: true)
    }

    @ViewBuilder private func portButtons(_ port: ListeningPort) -> some View {
        Button("Open in Browser") { vm.openInBrowser(port) }.pointerCursor()
        Button("Quit") { vm.confirmation = .quitPort(port, .graceful) }
            .pointerCursor()
            .disabled(vm.isWorking)
        Button("Force Quit", role: .destructive) { vm.confirmation = .quitPort(port, .force) }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .pointerCursor()
            .disabled(vm.isWorking)
    }

    @ViewBuilder private func jobDetail(_ job: ScheduledJob) -> some View {
        HStack(spacing: 10) {
            Text(job.label).font(.headline).lineLimit(1)
            Spacer()
            jobButtons(job)
        }
        detailRow("Schedule", job.schedule)
        detailRow("Status", job.statusLabel)
        if let process = vm.jobProcess { processRows(process) } else { detailRow("Command", job.command, monospaced: true) }
        if let plist = job.plistPath { detailRow("Plist", plist, monospaced: true) }
        if !job.logPaths.isEmpty {
            detailRow("Log", job.logPaths.joined(separator: "  ·  "), monospaced: true)
            ScrollView {
                Text(vm.jobLog.isEmpty ? "Log is empty or not created yet." : vm.jobLog)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(vm.jobLog.isEmpty ? .tertiary : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 130)
            .padding(8)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder private func loginItemDetail(_ item: LoginItem) -> some View {
        HStack(spacing: 10) {
            Text(item.name).font(.headline).lineLimit(1)
            Spacer()
            if let path = item.path, !item.isMissing { Button("Reveal") { vm.reveal(path) }.pointerCursor() }
            if !item.isMissing {
                Button(item.isEnabled ? "Turn Off" : "Turn On") { Task { await vm.setLoginItem(item, enabled: !item.isEnabled) } }
                    .pointerCursor()
                    .disabled(vm.isWorking)
            }
            Button("Remove", role: .destructive) { vm.confirmation = .forgetLoginItem(item) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .pointerCursor()
                .disabled(vm.isWorking)
        }
        detailRow("Status", item.statusLabel)
        detailRow("Location", item.path ?? "Unknown — the app was probably uninstalled", monospaced: item.path != nil)
    }

    @ViewBuilder private func jobButtons(_ job: ScheduledJob) -> some View {
        if let log = job.logPaths.first { Button("Open Log") { vm.openLog(log) }.pointerCursor() }
        if let plist = job.plistPath { Button("Reveal") { vm.reveal(plist) }.pointerCursor() }
        if job.source.isManageable {
            if job.isRunning {
                Button("Stop") { vm.confirmation = .stopJob(job) }.pointerCursor().disabled(vm.isWorking)
            }
            Button("Run Now") { Task { await vm.runNow(job) } }
                .pointerCursor()
                .disabled(vm.isWorking || !job.isLoaded)
            if job.isLoaded {
                Button("Turn Off") { vm.confirmation = .turnOff(job) }.pointerCursor().disabled(vm.isWorking)
            } else {
                Button("Turn On") { Task { await vm.turnOn(job) } }.pointerCursor().disabled(vm.isWorking)
            }
        }
        if job.source.isDeletable {
            Button("Delete", role: .destructive) { vm.confirmation = .deleteJob(job) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .pointerCursor()
                .disabled(vm.isWorking)
        }
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
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
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
