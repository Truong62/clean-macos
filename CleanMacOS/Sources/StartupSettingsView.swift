import SwiftUI
import UniformTypeIdentifiers

struct StartupSettingsView: View {
    @AppStorage(StartupSettings.lockKey) private var locksScreen = false
    @AppStorage(StartupSettings.keepAwakeKey) private var keepsAwake = false
    @State private var apps = StartupSettings.apps()
    @State private var opensAtLogin = OpenAtLogin.isEnabled
    @State private var autoRestart: Bool?
    @State private var fileVaultIsOn: Bool?
    @State private var autoLoginUser: String?
    @State private var hasLoaded = false
    @State private var isChangingAutoRestart = false
    @State private var autoRestartError = ""

    private var missing: [StartupReadiness] {
        StartupReadiness.missing(autoRestart: autoRestart, fileVaultIsOn: fileVaultIsOn,
                                 autoLoginUser: autoLoginUser, opensAtLogin: opensAtLogin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            summary
            VStack(spacing: 0) {
                powerStep
                diskStep
                loginStep
                appStep
                appsStep
                lockStep
                awakeStep
            }
        }
        .task { await loadStatus() }
        .onChange(of: apps) { _, apps in StartupSettings.save(apps) }
        .onChange(of: keepsAwake) { _, isOn in StartupRoutine.shared.setKeepAwake(isOn) }
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
                Text("Power comes back, the Mac turns on, logs in and runs your apps — no one at the desk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(LinearGradient(colors: colors.map { $0.opacity(0.14) }, startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(colors[0].opacity(0.35)))
    }

    private var powerStep: some View {
        FlowStep(icon: "bolt.fill", colors: [.yellow, .orange], title: "Power returns",
                 detail: autoRestart == nil && hasLoaded ? "This Mac doesn't offer it — Mac laptops run on battery instead"
                     : autoRestartError.isEmpty ? "The Mac turns itself on · macOS asks for your password to change this" : autoRestartError,
                 state: autoRestart == true ? .ready : autoRestart == nil ? .unavailable : .attention) {
            if isChangingAutoRestart { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { autoRestart ?? false }, set: { changeAutoRestart($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(autoRestart == nil || isChangingAutoRestart)
        }
    }

    private var diskStep: some View {
        FlowStep(icon: "lock.open.fill", colors: [.teal, .cyan], title: "No disk password",
                 detail: fileVaultIsOn == true ? "FileVault is on — the Mac stops and waits for your disk password"
                     : "FileVault is off, so the Mac can start up without you",
                 state: fileVaultIsOn == true ? .attention : .ready) {
            if fileVaultIsOn == true {
                Button("FileVault…") { NSWorkspace.shared.open(SystemPower.fileVaultSettingsURL) }.pointerCursor()
            }
        }
    }

    private var loginStep: some View {
        FlowStep(icon: "person.crop.circle.fill", colors: [.blue, .indigo], title: "Log in automatically",
                 detail: autoLoginUser.map { "Signs in as \($0)" } ?? "Off — the Mac waits at the login screen",
                 state: autoLoginUser == nil ? .attention : .ready) {
            Button("Users & Groups…") { NSWorkspace.shared.open(SystemPower.usersSettingsURL) }.pointerCursor()
        }
    }

    private var appStep: some View {
        FlowStep(icon: "sparkles", colors: [.purple, .pink], title: "Clean macOS opens",
                 detail: "Opens at login so the steps below can run",
                 state: opensAtLogin ? .ready : .attention) {
            Toggle("", isOn: $opensAtLogin)
                .labelsHidden()
                .toggleStyle(.switch)
                .onChange(of: opensAtLogin) { _, isOn in
                    OpenAtLogin.set(isOn)
                    opensAtLogin = OpenAtLogin.isEnabled
                }
        }
    }

    private var appsStep: some View {
        FlowStep(icon: "square.stack.3d.up.fill", colors: [.pink, .orange], title: "Open your apps",
                 detail: "Once per startup, within 10 minutes of the Mac turning on",
                 state: apps.isEmpty ? .off : .ready) {
            Button { addApps() } label: { Label("Add App…", systemImage: "plus") }.pointerCursor()
            Button { Task { await StartupRoutine.shared.run(apps, locksScreen: false) } } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .pointerCursor()
            .disabled(apps.isEmpty)
            .help("Open the apps now to test, without locking the screen")
        } extra: {
            if !apps.isEmpty {
                VStack(spacing: 6) {
                    ForEach($apps) { $app in StartupAppRow(app: $app) { apps.removeAll { $0.id == app.id } } }
                }
            }
        }
    }

    private var lockStep: some View {
        FlowStep(icon: "lock.fill", colors: [.indigo, .purple], title: "Lock the screen",
                 detail: "Right after the apps start, so the desktop isn't left open",
                 state: locksScreen ? .ready : .off) {
            Toggle("", isOn: $locksScreen).labelsHidden().toggleStyle(.switch)
        }
    }

    private var awakeStep: some View {
        FlowStep(icon: "sun.max.fill", colors: [.orange, .yellow], title: "Keep the screen awake",
                 detail: "Like caffeinate -d, for as long as Clean macOS runs",
                 state: keepsAwake ? .ready : .off, isLast: true) {
            Toggle("", isOn: $keepsAwake).labelsHidden().toggleStyle(.switch)
        }
    }

    private func loadStatus() async {
        let (restart, fileVault, user) = await Task.detached(priority: .utility) {
            (SystemPower.autoRestart(), SystemPower.fileVaultIsOn(), SystemPower.autoLoginUser())
        }.value
        autoRestart = restart
        fileVaultIsOn = fileVault
        autoLoginUser = user
        hasLoaded = true
    }

    private func changeAutoRestart(_ isOn: Bool) {
        isChangingAutoRestart = true
        Task {
            let error = await Task.detached { SystemPower.setAutoRestart(isOn) }.value
            autoRestartError = error ?? ""
            await loadStatus()
            isChangingAutoRestart = false
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let known = Set(apps.map(\.path))
        apps += panel.urls.map(\.path).filter { !known.contains($0) }.map { StartupApp(path: $0) }
    }
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

struct FlowStep<Trailing: View, Extra: View>: View {
    let icon: String
    let colors: [Color]
    let title: String
    let detail: String
    let state: FlowStepState
    var isLast = false
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder var extra: () -> Extra

    init(icon: String, colors: [Color], title: String, detail: String, state: FlowStepState, isLast: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.icon = icon
        self.colors = colors
        self.title = title
        self.detail = detail
        self.state = state
        self.isLast = isLast
        self.trailing = trailing
        self.extra = extra
    }

    private var isLit: Bool { state == .ready }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                badge
                if !isLast { FlowConnector(colors: colors, isFlowing: isLit) }
            }
            .frame(width: 40)
            card.padding(.bottom, isLast ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var badge: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12))
            .saturation(isLit ? 1 : 0.25)
            .opacity(isLit ? 1 : 0.75)
            .shadow(color: colors[0].opacity(isLit ? 0.5 : 0), radius: 8, y: 3)
            .animation(.easeOut(duration: 0.3), value: isLit)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).fontWeight(.semibold)
                        Text(state.label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .foregroundStyle(state.color)
                            .background(state.color.opacity(0.14), in: Capsule())
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                trailing()
            }
            extra()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(LinearGradient(colors: colors.map { $0.opacity(isLit ? 0.55 : 0.12) },
                                             startPoint: .leading, endPoint: .trailing), lineWidth: 1)
        )
    }
}

struct FlowConnector: View {
    let colors: [Color]
    let isFlowing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Line()
                .stroke(LinearGradient(colors: isFlowing ? colors : [Color.secondary.opacity(0.35)], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5], dashPhase: phase))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isFlowing ? colors[colors.count - 1] : Color.secondary.opacity(0.5))
                .padding(.bottom, 2)
        }
        .padding(.top, 4)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { phase = -10 }
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            }
        }
    }
}

struct StartupAppRow: View {
    @Binding var app: StartupApp
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 24, height: 24)
            Text(app.name).fontWeight(.medium).lineLimit(1)
            Spacer()
            Picker("", selection: $app.action) {
                ForEach(StartupAction.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 118)
            if app.action != .keepOpen {
                Stepper("\(app.delaySeconds) s", value: $app.delaySeconds, in: 1...300)
                    .monospacedDigit()
                    .frame(width: 84)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}
