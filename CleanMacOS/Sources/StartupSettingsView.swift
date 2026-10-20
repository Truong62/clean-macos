import SwiftUI

struct StartupSettingsView: View {
    @AppStorage(StartupSettings.lockKey) private var locksScreen = false
    @AppStorage(StartupSettings.lockDelayKey) private var lockDelay = StartupSettings.defaultLockDelay
    @State private var autoRestart: Bool?
    @State private var fileVaultIsOn: Bool?
    @State private var autoLoginUser: String?
    @State private var loginItems: [LoginItem] = []
    @State private var jobs: [ScheduledJob] = []
    @State private var opensAtLogin = OpenAtLogin.isEnabled
    @State private var hasLoaded = false
    @State private var isWorking = false
    @State private var message = ""
    @State private var selected: StartupStep?

    private let loginItemsService = LoginItemsService()
    private let jobsService = ScheduledJobsService()

    init(initialStep: StartupStep? = nil) {
        _selected = State(initialValue: initialStep)
    }

    private var missing: [StartupReadiness] {
        StartupReadiness.missing(autoRestart: autoRestart, fileVaultIsOn: fileVaultIsOn, autoLoginUser: autoLoginUser)
    }

    private var openApps: [LoginItem] { loginItems.filter { $0.isEnabled && !$0.isMissing } }
    private var backgroundJobs: [ScheduledJob] { StartupJobs.atLogin(jobs) }
    private var lockerJob: ScheduledJob? { backgroundJobs.first { StartupJobs.locksScreen($0) && $0.isLoaded } }
    private var hasKeepAwake: Bool { backgroundJobs.contains(where: StartupJobs.keepsAwake) }
    private var skipsPassword: Bool { autoLoginUser != nil && fileVaultIsOn != true }

    private var steps: [FlowNode] {
        [
            FlowNode(step: .power, icon: "bolt.fill", colors: [.yellow, .orange], name: "Power", title: "Turn on when power returns",
                     detail: autoRestart == nil && hasLoaded ? "This Mac doesn't offer it — Mac laptops run on battery instead"
                         : "The Mac starts by itself once power is back. macOS asks for your password to change this.",
                     state: autoRestart == true ? .ready : autoRestart == nil ? .unavailable : .attention),
            FlowNode(step: .password, icon: "key.fill", colors: [.teal, .cyan], name: "No password", title: "Log in without a password",
                     detail: fileVaultIsOn == true ? "FileVault is on — the Mac waits for the disk password before anything below starts."
                         : autoLoginUser.map { "Logs straight in as \($0). Turn it off and the Mac waits for your password; turning it on happens in Users & Groups." }
                         ?? "Off — the Mac waits for your password. Turn it on in Users & Groups › Automatically log in as.",
                     state: skipsPassword ? .ready : .attention),
            FlowNode(step: .apps, icon: "square.stack.3d.up.fill", colors: [.pink, .orange], name: "Apps", title: "Open your apps",
                     detail: "macOS opens these right after logging in — the same list as Ports & Jobs › Login Items.",
                     state: openApps.isEmpty ? .off : .ready),
            FlowNode(step: .background, icon: "gearshape.2.fill", colors: [.purple, .pink], name: "Background", title: "Background jobs",
                     detail: "Your LaunchAgents that start at login and keep running, like caffeinate -d to keep the screen awake.",
                     state: backgroundJobs.contains(where: \.isLoaded) ? .ready : .off),
            FlowNode(step: .lock, icon: "lock.fill", colors: [.indigo, .purple], name: "Lock", title: "Lock the screen",
                     detail: lockerJob.map { "\($0.label) already locks the screen after login. Turn this on only if you remove it." }
                         ?? "\(lockDelay) s after logging in without a password, so the desktop isn't left open.",
                     state: locksScreen || lockerJob != nil ? .ready : .off),
        ]
    }

    private var current: FlowNode {
        let steps = steps
        return steps.first { $0.step == selected } ?? steps.first { $0.state == .attention } ?? steps[2]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            FlowCanvas(nodes: steps, selected: current.step) { step in
                withAnimation(.spring(duration: 0.3)) { selected = step }
            }
            FlowInspector(node: current) { controls(current.step) } extra: { extra(current.step) }
                .id(current.step)
                .transition(.opacity)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .task { await load() }
    }

    private var summary: some View {
        let isReady = hasLoaded && missing.isEmpty
        let colors: [Color] = isReady ? [.green, .mint] : [.orange, .pink]
        return HStack(spacing: 14) {
            Image(systemName: isReady ? "bolt.badge.checkmark.fill" : "bolt.trianglebadge.exclamationmark.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: colors[0].opacity(0.45), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(!hasLoaded ? "Checking this Mac…" : isReady ? "Recovers on its own after a power cut"
                     : "\(missing.count) \(missing.count == 1 ? "step needs" : "steps need") you")
                    .font(.headline)
                Text("Power comes back → the Mac turns on → logs in → opens your apps and background jobs → locks the screen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
        }
        .padding(14)
        .background(LinearGradient(colors: colors.map { $0.opacity(0.14) }, startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(colors[0].opacity(0.35)))
    }

    @ViewBuilder private func controls(_ step: StartupStep) -> some View {
        switch step {
        case .power:
            switchToggle(Binding(get: { autoRestart ?? false }, set: { isOn in perform { SystemPower.setAutoRestart(isOn) } }))
                .disabled(autoRestart == nil)
        case .password:
            if fileVaultIsOn == true {
                Button("FileVault…") { NSWorkspace.shared.open(SystemPower.fileVaultSettingsURL) }.pointerCursor()
            }
            switchToggle(Binding(get: { autoLoginUser != nil }, set: { isOn in
                if isOn { NSWorkspace.shared.open(SystemPower.usersSettingsURL) } else { perform { SystemPower.turnOffAutoLogin() } }
            }))
        case .apps:
            Button { addApp() } label: { Label("Add App…", systemImage: "plus") }.pointerCursor()
        case .background:
            if !hasKeepAwake {
                Button { addKeepAwake() } label: { Label("Add caffeinate -d", systemImage: "sun.max.fill") }
                    .pointerCursor()
                    .help("Keeps the screen awake from login on, as a LaunchAgent")
            }
        case .lock:
            Stepper("\(lockDelay) s", value: $lockDelay, in: 0...60)
                .monospacedDigit()
                .frame(width: 80)
            switchToggle($locksScreen)
        }
    }

    @ViewBuilder private func extra(_ step: StartupStep) -> some View {
        switch step {
        case .apps:
            VStack(spacing: 6) {
                ForEach(loginItems) { item in
                    StartupRow(icon: Image(nsImage: NSWorkspace.shared.icon(forFile: item.path ?? "/Applications")),
                               title: item.name, subtitle: item.statusLabel, tags: [],
                               isOn: Binding(get: { item.isEnabled }, set: { setLoginItem(item, $0) }))
                        .disabled(item.isMissing)
                }
            }
        case .background:
            VStack(spacing: 6) {
                ForEach(backgroundJobs) { job in
                    StartupRow(icon: Image(systemName: "terminal.fill"), title: job.label,
                               subtitle: "\(job.statusLabel) · \(job.command)",
                               tags: [StartupJobs.keepsAwake(job) ? "keeps awake" : nil,
                                      StartupJobs.locksScreen(job) ? "locks screen" : nil].compactMap { $0 },
                               isOn: Binding(get: { job.isLoaded }, set: { setJob(job, $0) }))
                }
            }
        case .lock:
            if locksScreen && !opensAtLogin {
                HStack {
                    Label("Clean macOS must open at login to lock the screen", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open at Login") {
                        OpenAtLogin.set(true)
                        opensAtLogin = OpenAtLogin.isEnabled
                    }
                    .pointerCursor()
                }
            }
        case .power, .password:
            EmptyView()
        }
    }

    private func switchToggle(_ isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).disabled(isWorking)
    }

    private func load() async {
        let (restart, fileVault, user) = await Task.detached(priority: .utility) {
            (SystemPower.autoRestart(), SystemPower.fileVaultIsOn(), SystemPower.autoLoginUser())
        }.value
        autoRestart = restart
        fileVaultIsOn = fileVault
        autoLoginUser = user
        loginItems = loginItemsService.list()
        jobs = await jobsService.list()
        opensAtLogin = OpenAtLogin.isEnabled
        hasLoaded = true
    }

    private func perform(_ adminChange: @escaping @Sendable () -> String?) {
        isWorking = true
        Task {
            message = await Task.detached { adminChange() }.value ?? ""
            await load()
            isWorking = false
        }
    }

    private func run(_ change: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            do {
                try await change()
                message = ""
            } catch {
                message = error.localizedDescription
            }
            await load()
            isWorking = false
        }
    }

    private func setLoginItem(_ item: LoginItem, _ isOn: Bool) {
        run { isOn ? try loginItemsService.turnOn(item) : try loginItemsService.turnOff(item) }
    }

    private func setJob(_ job: ScheduledJob, _ isOn: Bool) {
        run { isOn ? try await jobsService.turnOn(job) : try await jobsService.turnOff(job) }
    }

    private func addKeepAwake() {
        run { try await jobsService.addAgent(label: StartupJobs.keepAwakeLabel, arguments: StartupJobs.keepAwakeArguments) }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try loginItemsService.add(url) }
    }
}

enum StartupStep: Hashable {
    case power, password, apps, background, lock
}

enum FlowStepState {
    case ready, attention, off, unavailable

    var label: String {
        switch self {
        case .ready: "Ready"
        case .attention: "Needs you"
        case .off: "Off"
        case .unavailable: "Not on this Mac"
        }
    }

    var color: Color {
        switch self {
        case .ready: .green
        case .attention: .orange
        case .off, .unavailable: .secondary
        }
    }
}

struct FlowNode: Identifiable {
    let step: StartupStep
    let icon: String
    let colors: [Color]
    let name: String
    let title: String
    let detail: String
    let state: FlowStepState

    var id: StartupStep { step }
    var isLit: Bool { state == .ready }
}

struct FlowCanvas: View {
    let nodes: [FlowNode]
    let selected: StartupStep
    let select: (StartupStep) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(isCompact: false)
            ScrollView(.horizontal, showsIndicators: false) { row(isCompact: true) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background(DotGrid().clipShape(RoundedRectangle(cornerRadius: 16)))
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func row(isCompact: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                if index > 0 {
                    FlowConnector(from: nodes[index - 1], to: node)
                        .frame(minWidth: 18, maxWidth: isCompact ? 18 : 120)
                        .frame(height: 58)
                }
                FlowNodeTile(node: node, isSelected: node.step == selected) { select(node.step) }
            }
        }
        .padding(10)
    }
}

struct FlowNodeTile: View {
    let node: FlowNode
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: node.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(LinearGradient(colors: node.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 16))
                        .saturation(node.isLit ? 1 : 0.2)
                        .opacity(node.isLit ? 1 : 0.7)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(isSelected ? Color.primary.opacity(0.85) : .clear, lineWidth: 2)
                                .padding(-4)
                        )
                        .shadow(color: node.colors[0].opacity(node.isLit ? 0.55 : 0), radius: isSelected ? 14 : 8, y: 4)
                        .overlay(alignment: .leading) { port.offset(x: -4) }
                        .overlay(alignment: .trailing) { port.offset(x: 4) }
                    Circle()
                        .fill(node.state.color)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 4, y: -4)
                }
                Text(node.name)
                    .font(.caption.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 72)
            .scaleEffect(isSelected ? 1.06 : isHovered ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering } }
        .pointerCursor()
        .help(node.title)
    }

    private var port: some View {
        Circle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(node.isLit ? node.colors[0] : Color.secondary.opacity(0.5), lineWidth: 1.5))
    }
}

struct FlowConnector: View {
    let from: FlowNode
    let to: FlowNode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    private var isFlowing: Bool { from.isLit }

    var body: some View {
        HStack(spacing: 0) {
            Line()
                .stroke(LinearGradient(colors: isFlowing ? [from.colors[1], to.colors[0]] : [Color.secondary.opacity(0.35)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5], dashPhase: phase))
                .frame(height: 2)
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 7))
                .foregroundStyle(isFlowing ? to.colors[0] : Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { phase = -10 }
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 16
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(.primary.opacity(0.12)))
                }
            }
        }
    }
}

struct FlowInspector<Controls: View, Extra: View>: View {
    let node: FlowNode
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: node.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: node.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(node.title).fontWeight(.semibold)
                        Text(node.state.label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(node.state.color)
                            .background(node.state.color.opacity(0.14), in: Capsule())
                    }
                    Text(node.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                controls()
            }
            extra()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(LinearGradient(colors: node.colors.map { $0.opacity(0.5) }, startPoint: .leading, endPoint: .trailing),
                              lineWidth: 1)
        )
    }
}

struct StartupRow: View {
    let icon: Image
    let title: String
    let subtitle: String
    let tags: [String]
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            icon
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).lineLimit(1)
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .foregroundStyle(.purple)
                            .background(Color.purple.opacity(0.14), in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
