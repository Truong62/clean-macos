import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var clipboard: ClipboardViewModel
    @EnvironmentObject var jira: JiraViewModel
    let navigate: (SidebarPage) -> Void

    @StateObject private var monitor = SystemMonitor()
    @State private var cpuHistory: [Double] = []
    @State private var memoryHistory: [Double] = []
    @State private var portCount: Int?
    @State private var jobCount: Int?
    @State private var startupMissing: Int?
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.general

    private static let historyLength = 40
    private static let sampleInterval: TimeInterval = 2
    private static let heroColors = [Color(red: 0.36, green: 0.30, blue: 0.86), Color(red: 0.62, green: 0.32, blue: 0.86),
                                     Color(red: 0.93, green: 0.42, blue: 0.62)]

    private var hasResults: Bool { !vm.artifacts.isEmpty }
    private var freeText: String { "\(monitor.diskFreeStr) free" }
    private var health: HomeHealth {
        HomeHealth.summarize(cpu: monitor.cpuUsage, memory: monitor.memPercent, disk: monitor.diskPercent, freeText: monitor.diskFreeStr)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                hero.homeAppear(0)
                vitals.homeAppear(1)
                HStack(alignment: .top, spacing: 18) {
                    if jira.isConfigured { jiraCard.homeAppear(2) }
                    cleanableCard.homeAppear(3)
                }
                toolsGrid.homeAppear(4)
                footer.homeAppear(5)
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(AuroraBackground())
        .sheet(isPresented: $vm.showResults) {
            CleanResultsView().environmentObject(vm)
        }
        .onAppear { monitor.startPublishing(interval: Self.sampleInterval) }
        .onDisappear { monitor.stopSampling() }
        .onReceive(monitor.$cpuUsage) { cpuHistory = Self.append($0, to: cpuHistory) }
        .onReceive(monitor.$memPercent) { memoryHistory = Self.append($0, to: memoryHistory) }
        .task { await loadCounts() }
    }

    private static func append(_ value: Double, to history: [Double]) -> [Double] {
        Array((history + [value]).suffix(historyLength))
    }

    private func loadCounts() async {
        async let ports = PortsService().list()
        async let jobs = ScheduledJobsService().list()
        async let startup = Task.detached(priority: .utility) { StartupReadiness.check().count }.value
        portCount = await ports.count
        startupMissing = await startup
        jobCount = await jobs.filter { $0.source == .userAgent || $0.source == .cron }.count
        if jira.isConfigured && jira.menuUpdatedAt == nil { await jira.refreshMenu() }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.7))
                Text(greeting)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                HStack(spacing: 10) {
                    Image(systemName: health.icon)
                        .font(.title3)
                        .foregroundStyle(health.isWarning ? Color.yellow : .white)
                        .symbolEffect(.bounce, value: health.isWarning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(health.title).font(.headline).foregroundStyle(.white)
                        Text(health.detail).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 10) {
                    primaryButton
                    if hasResults {
                        Text("\(formatBytes(vm.totalCleanableSize)) ready to clean")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            DiskGauge(usedPercent: monitor.diskPercent.rounded(), freeText: freeText)
        }
        .padding(28)
        .background(heroBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .shadow(color: Self.heroColors[1].opacity(0.35), radius: 24, y: 12)
    }

    private var heroBackground: some View {
        ZStack {
            LinearGradient(colors: Self.heroColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            SoftGlow(color: .white.opacity(0.28)).frame(width: 460, height: 460).offset(x: 260, y: -130)
            SoftGlow(color: Color(red: 0.3, green: 0.85, blue: 0.95).opacity(0.45)).frame(width: 420, height: 420).offset(x: -300, y: 140)
        }
    }

    private var primaryButton: some View {
        Button {
            navigate(.cleanDisk)
            if !hasResults { Task { await vm.scan() } }
        } label: {
            HStack(spacing: 8) {
                if vm.isScanning {
                    ProgressView().controlSize(.small).tint(Self.heroColors[0])
                } else {
                    Image(systemName: hasResults ? "trash.fill" : "sparkles")
                }
                Text(vm.isScanning ? "Scanning…" : hasResults ? "Review & Clean" : "Scan & Clean")
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .foregroundStyle(Self.heroColors[0])
            .background(Capsule().fill(.white))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(vm.isScanning)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    // MARK: - Vitals

    private var vitals: some View {
        HStack(spacing: 14) {
            VitalTile(title: "CPU", icon: "cpu", value: "\(Int(monitor.cpuUsage.rounded()))%",
                      caption: monitor.cpuName.isEmpty ? "Processor load" : monitor.cpuName,
                      history: cpuHistory, colors: [.blue, .cyan])
            VitalTile(title: "Memory", icon: "memorychip", value: "\(Int(monitor.memPercent.rounded()))%",
                      caption: "\(monitor.memUsedStr) of \(monitor.memTotalStr)",
                      history: memoryHistory, colors: [.purple, .pink])
            VitalTile(title: "Disk", icon: "internaldrive", value: monitor.diskFreeStr,
                      caption: "free of \(monitor.diskTotalStr) · up \(monitor.uptime)",
                      fraction: monitor.diskPercent.rounded() / 100, colors: [.orange, .yellow])
        }
    }

    // MARK: - Jira

    private var jiraCard: some View {
        let sprint = jira.menu.sprint
        let doing = jira.menu.rows.filter { $0.group == .doing }.prefix(3)
        return VStack(alignment: .leading, spacing: 14) {
            cardHeader(icon: "checklist", title: "Jira", colors: [.blue, .indigo]) { navigate(.jira) }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sprint.name.isEmpty ? "No active sprint" : sprint.name)
                    .font(.headline)
                    .lineLimit(1)
                if let days = sprint.daysLeft {
                    Text("· \(days)d left").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("This month").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(sprint.monthDone)/\(sprint.monthTasks) done · \(sprint.monthPoints) \(sprint.pointLabel)")
                        .font(.caption.weight(.semibold))
                }
                ProgressView(value: Double(sprint.monthDone), total: Double(max(sprint.monthTasks, 1)))
                    .tint(.indigo)
            }
            if doing.isEmpty {
                Text("Nothing in progress").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(doing)) { row in
                        Button { jira.open(issueKey: row.id) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(.blue).frame(width: 6, height: 6)
                                Text(row.id).font(.caption.monospaced().weight(.semibold)).foregroundStyle(.blue)
                                Text(row.summary).font(.callout).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .homeCard()
    }

    // MARK: - Cleanable

    private var cleanableCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(icon: "sparkles", title: "Cleanable", colors: [.teal, .green]) { navigate(.cleanDisk) }
            if hasResults {
                Text(formatBytes(vm.totalCleanableSize))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                CleanableBar(segments: vm.categoryCounts)
                VStack(spacing: 8) {
                    ForEach(vm.categoryCounts.prefix(5), id: \.0) { category, count, size in
                        HStack(spacing: 8) {
                            Circle().fill(category.color.gradient).frame(width: 8, height: 8)
                            Text(category.displayName).font(.callout)
                            Text("\(count)").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            Text(formatBytes(size)).font(.callout.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 30))
                        .foregroundStyle(LinearGradient(colors: [.teal, .green], startPoint: .top, endPoint: .bottom))
                    Text("Find caches, logs and build leftovers").font(.headline)
                    Text("A quick scan shows how much space you can take back, grouped by category.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .homeCard()
    }

    private func cardHeader(icon: String, title: String, colors: [Color], action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 7))
            Text(title.uppercased()).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
            Spacer()
            Button("Open", action: action)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .pointerCursor()
        }
    }

    // MARK: - Tools

    private var toolsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ToolTile(icon: "doc.text.magnifyingglass", title: "Large Files", stat: "Find space hogs",
                     colors: [.orange, .red]) { navigate(.largeFiles) }
            ToolTile(icon: "trash.fill", title: "Uninstall Apps", stat: "Remove apps and leftovers",
                     colors: [.pink, .red]) { navigate(.uninstall) }
            ToolTile(icon: "doc.on.clipboard.fill", title: "Clipboard", stat: "\(clipboard.items.count) items saved · ⌘⇧V",
                     colors: [.indigo, .purple]) { navigate(.clipboard) }
            ToolTile(icon: "network", title: "Ports & Jobs",
                     stat: [portCount.map { "\($0) ports" }, jobCount.map { "\($0) jobs" }].compactMap { $0 }.joined(separator: " · "),
                     colors: [.cyan, .blue]) { navigate(.portsJobs) }
            ToolTile(icon: "memorychip", title: "RAM", stat: "\(Int(monitor.memPercent.rounded()))% used",
                     colors: [.mint, .teal]) { navigate(.ram) }
            ToolTile(icon: "display.2", title: "Displays", stat: "\(NSScreen.screens.count) connected",
                     colors: [.purple, .blue]) { navigate(.displays) }
            ToolTile(icon: "bolt.fill", title: "Power Recovery",
                     stat: startupMissing.map { $0 == 0 ? "Ready after a power cut" : "\($0) \($0 == 1 ? "step needs" : "steps need") you" } ?? "",
                     colors: [.yellow, .orange]) {
                settingsTab = .startup
                navigate(.settings)
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        if let info = vm.diskInfo {
            HStack(spacing: 8) {
                chip("desktopcomputer", info.hostname)
                chip("apple.logo", info.osVersion)
                chip("cpu", info.arch)
                if !vm.snapshots.isEmpty { chip("clock.arrow.circlepath", "\(vm.snapshots.count) snapshots") }
                Spacer()
            }
        }
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
    }
}
