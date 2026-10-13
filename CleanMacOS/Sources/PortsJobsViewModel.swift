import AppKit
import SwiftUI

enum PortsJobsTab: String, CaseIterable, Identifiable {
    case ports = "Ports"
    case jobs = "Scheduled Jobs"

    var id: String { rawValue }
}

enum PortsJobsConfirmation {
    case quitPort(ListeningPort, ProcessTerminationMode)
    case turnOff(ScheduledJob)

    var title: String {
        switch self {
        case .quitPort(let port, let mode): "\(mode.label) \(port.command) on port \(port.port)?"
        case .turnOff(let job): "Turn off \(job.label)?"
        }
    }

    var message: String {
        switch self {
        case .quitPort(let port, _): "PID \(port.pid) will stop and port \(port.port) will be freed."
        case .turnOff: "The job is unloaded and stays off after restart until you turn it on again."
        }
    }

    var actionLabel: String {
        switch self {
        case .quitPort(_, let mode): mode.label
        case .turnOff: "Turn Off"
        }
    }
}

@MainActor
final class PortsJobsViewModel: ObservableObject {
    @Published var tab: PortsJobsTab = .ports
    @Published var ports: [ListeningPort] = []
    @Published var jobs: [ScheduledJob] = []
    @Published var searchText = ""
    @Published var showsSystemJobs = false
    @Published var selectedPortID: ListeningPort.ID?
    @Published var selectedJobID: ScheduledJob.ID?
    @Published var isRefreshing = false
    @Published var isWorking = false
    @Published var statusMessage = ""
    @Published var confirmation: PortsJobsConfirmation?

    private static let refreshInterval: Duration = .seconds(5)
    private let portsService: PortsService
    private let jobsService: ScheduledJobsService
    private let processService: ProcessService
    private var refreshTask: Task<Void, Never>?

    init(portsService: PortsService = PortsService(), jobsService: ScheduledJobsService = ScheduledJobsService(),
         processService: ProcessService = ProcessService()) {
        self.portsService = portsService
        self.jobsService = jobsService
        self.processService = processService
    }

    var filteredPorts: [ListeningPort] {
        ports.filter { matches("\($0.port) \($0.command) \($0.pid)") }
    }

    var filteredJobs: [ScheduledJob] {
        jobs.filter { (showsSystemJobs || $0.source == .userAgent || $0.source == .cron) && matches("\($0.label) \($0.command)") }
    }

    var selectedPort: ListeningPort? { ports.first { $0.id == selectedPortID } }
    var selectedJob: ScheduledJob? { jobs.first { $0.id == selectedJobID } }

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
        isRefreshing = false
    }

    func confirm() async {
        guard let confirmation else { return }
        self.confirmation = nil
        switch confirmation {
        case .quitPort(let port, let mode):
            await perform { _ = try await self.processService.terminate(port.process, mode: mode) }
        case .turnOff(let job):
            await perform { try await self.jobsService.turnOff(job) }
        }
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
