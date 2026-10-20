import AppKit
import SwiftUI

enum PortsJobsTab: String, CaseIterable, Identifiable {
    case ports = "Ports"
    case jobs = "Scheduled Jobs"
    case loginItems = "Login Items"

    var id: String { rawValue }
}

enum PortsJobsConfirmation {
    case quitPort(ListeningPort, ProcessTerminationMode)
    case turnOff(ScheduledJob)
    case stopJob(ScheduledJob)
    case deleteJob(ScheduledJob)
    case forgetLoginItem(LoginItem)

    var title: String {
        switch self {
        case .quitPort(let port, let mode): "\(mode.label) \(port.command) on port \(port.port)?"
        case .turnOff(let job): "Turn off \(job.label)?"
        case .stopJob(let job): "Stop \(job.label)?"
        case .deleteJob(let job): "Delete \(job.label)?"
        case .forgetLoginItem(let item): "Remove \(item.name) from Login Items?"
        }
    }

    var message: String {
        switch self {
        case .quitPort(let port, _): "PID \(port.pid) will stop and port \(port.port) will be freed."
        case .turnOff: "The job is unloaded and stays off after restart until you turn it on again."
        case .stopJob(let job): "Sends SIGTERM to PID \(job.pid.map(String.init) ?? "?"). A job set to keep alive starts again; use Turn Off to keep it stopped."
        case .deleteJob(let job):
            job.cronLine.map { "This line is removed from your crontab:\n\($0)" }
                ?? "The job is unloaded and its plist is moved to the Trash."
        case .forgetLoginItem: "It no longer opens at login and disappears from this list. The app itself is not deleted."
        }
    }

    var actionLabel: String {
        switch self {
        case .quitPort(_, let mode): mode.label
        case .turnOff: "Turn Off"
        case .stopJob: "Stop"
        case .deleteJob: "Delete"
        case .forgetLoginItem: "Remove"
        }
    }
}

@MainActor
final class PortsJobsViewModel: ObservableObject {
    @Published var tab: PortsJobsTab = .ports
    @Published var ports: [ListeningPort] = []
    @Published var jobs: [ScheduledJob] = []
    @Published var loginItems: [LoginItem] = []
    @Published var selectedLoginItemID: LoginItem.ID?
    @Published var searchText = ""
    @Published var showsSystemJobs = false
    @Published var selectedPortID: ListeningPort.ID?
    @Published var selectedJobID: ScheduledJob.ID?
    @Published var isRefreshing = false
    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var confirmation: PortsJobsConfirmation?
    @Published var portDetails: ProcessDetails?
    @Published var jobProcess: ProcessDetails?
    @Published var jobLog = ""

    private static let refreshInterval: Duration = .seconds(5)
    private let portsService: PortsService
    private let jobsService: ScheduledJobsService
    private let processService: ProcessService
    private let loginItemsService: LoginItemsService
    private var refreshTask: Task<Void, Never>?

    init(portsService: PortsService = PortsService(), jobsService: ScheduledJobsService = ScheduledJobsService(),
         processService: ProcessService = ProcessService(), loginItemsService: LoginItemsService = LoginItemsService()) {
        self.portsService = portsService
        self.jobsService = jobsService
        self.processService = processService
        self.loginItemsService = loginItemsService
    }

    var filteredPorts: [ListeningPort] {
        ports.filter { matches("\($0.port) \($0.command) \($0.pid)") }
    }

    var filteredJobs: [ScheduledJob] {
        jobs.filter { (showsSystemJobs || $0.source == .userAgent || $0.source == .cron) && matches("\($0.label) \($0.command)") }
    }

    var filteredLoginItems: [LoginItem] {
        loginItems.filter { matches("\($0.name) \($0.path ?? "")") }
    }

    var selectedPort: ListeningPort? { ports.first { $0.id == selectedPortID } }
    var selectedJob: ScheduledJob? { jobs.first { $0.id == selectedJobID } }
    var selectedLoginItem: LoginItem? { loginItems.first { $0.id == selectedLoginItemID } }

    var isConfirming: Binding<Bool> {
        Binding(get: { self.confirmation != nil }, set: { if !$0 { self.confirmation = nil } })
    }

    func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
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
        async let listedPorts = portsService.list()
        async let listedJobs = jobsService.list()
        ports = await listedPorts
        jobs = await listedJobs
        loginItems = loginItemsService.list()
        isRefreshing = false
        await loadDetails()
    }

    func loadDetails() async {
        if let port = selectedPort {
            portDetails = await portsService.details(pid: port.pid)
        } else {
            portDetails = nil
        }
        if let pid = selectedJob?.pid {
            jobProcess = await portsService.details(pid: pid)
        } else {
            jobProcess = nil
        }
        let paths = selectedJob?.logPaths ?? []
        jobLog = await Task.detached(priority: .utility) {
            paths.compactMap { path in
                ScheduledJobsService.logTail(path).map { paths.count > 1 ? "── \(path)\n\($0)" : $0 }
            }.joined(separator: "\n")
        }.value
    }

    func confirm(_ confirmation: PortsJobsConfirmation) async {
        self.confirmation = nil
        switch confirmation {
        case .quitPort(let port, let mode):
            await perform { _ = try await self.processService.terminate(port.process, mode: mode) }
        case .turnOff(let job):
            await perform { try await self.jobsService.turnOff(job) }
        case .stopJob(let job):
            await perform { try await self.jobsService.stop(job) }
        case .deleteJob(let job):
            await perform { try await self.jobsService.delete(job) }
            selectedJobID = nil
        case .forgetLoginItem(let item):
            await perform { try self.loginItemsService.forget(item) }
            selectedLoginItemID = nil
        }
    }

    func setLoginItem(_ item: LoginItem, enabled: Bool) async {
        await perform {
            if enabled { try self.loginItemsService.turnOn(item) } else { try self.loginItemsService.turnOff(item) }
        }
    }

    func addLoginItem() async {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open at Login"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await perform { try self.loginItemsService.add(url) }
    }

    func runNow(_ job: ScheduledJob) async {
        await perform { try await self.jobsService.runNow(job) }
    }

    func turnOn(_ job: ScheduledJob) async {
        await perform { try await self.jobsService.turnOn(job) }
    }

    func openInBrowser(_ port: ListeningPort) {
        guard let url = port.url else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openLog(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            statusMessage = "Log file does not exist yet: \(path)"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await action()
            statusMessage = ""
        } catch {
            statusMessage = error.localizedDescription
        }
        await refresh()
    }

    private func matches(_ text: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }
}
