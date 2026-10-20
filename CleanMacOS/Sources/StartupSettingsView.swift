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

    @State private var selected: StartupStep?

    private var steps: [FlowNode] {
        [
            FlowNode(step: .power, icon: "bolt.fill", colors: [.yellow, .orange], name: "Power", title: "Power returns",
                     detail: autoRestart == nil && hasLoaded ? "This Mac doesn't offer it — Mac laptops run on battery instead"
                         : autoRestartError.isEmpty ? "The Mac turns itself on when power comes back. macOS asks for your password to change this."
                         : autoRestartError,
                     state: autoRestart == true ? .ready : autoRestart == nil ? .unavailable : .attention),
            FlowNode(step: .disk, icon: "lock.open.fill", colors: [.teal, .cyan], name: "Unlock", title: "No disk password",
                     detail: fileVaultIsOn == true ? "FileVault is on — the Mac stops and waits for your disk password, so nothing after this runs."
                         : "FileVault is off, so the Mac can start up without anyone typing a password.",
                     state: fileVaultIsOn == true ? .attention : .ready),
            FlowNode(step: .login, icon: "person.crop.circle.fill", colors: [.blue, .indigo], name: "Log in", title: "Log in automatically",
                     detail: autoLoginUser.map { "Signs in as \($0) without the login screen." } ?? "Off — the Mac waits at the login screen. Turn it on in Users & Groups.",
                     state: autoLoginUser == nil ? .attention : .ready),
            FlowNode(step: .app, icon: "sparkles", colors: [.purple, .pink], name: "Clean macOS", title: "Clean macOS opens",
                     detail: "Opens at login so the next steps can run.", state: opensAtLogin ? .ready : .attention),
            FlowNode(step: .apps, icon: "square.stack.3d.up.fill", colors: [.pink, .orange], name: "Apps", title: "Open your apps",
                     detail: "Once per startup, within 10 minutes of the Mac turning on. Each app can stay open, hide or quit after a few seconds.",
                     state: apps.isEmpty ? .off : .ready),
            FlowNode(step: .lock, icon: "lock.fill", colors: [.indigo, .purple], name: "Lock", title: "Lock the screen",
                     detail: "Right after the apps start, so the desktop isn't left open.", state: locksScreen ? .ready : .off),
            FlowNode(step: .awake, icon: "sun.max.fill", colors: [.orange, .yellow], name: "Stay awake", title: "Keep the screen awake",
                     detail: "Like caffeinate -d, for as long as Clean macOS runs.", state: keepsAwake ? .ready : .off),
        ]
    }

    private var current: FlowNode {
        let steps = steps
        let fallback = steps.first { $0.state == .attention } ?? steps[4]
        return steps.first { $0.step == selected } ?? fallback
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

    @ViewBuilder private func controls(_ step: StartupStep) -> some View {
        switch step {
        case .power:
            if isChangingAutoRestart { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { autoRestart ?? false }, set: { changeAutoRestart($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(autoRestart == nil || isChangingAutoRestart)
        case .disk:
            if fileVaultIsOn == true {
                Button("FileVault…") { NSWorkspace.shared.open(SystemPower.fileVaultSettingsURL) }.pointerCursor()
            }
        case .login:
            Button("Users & Groups…") { NSWorkspace.shared.open(SystemPower.usersSettingsURL) }.pointerCursor()
        case .app:
            Toggle("", isOn: $opensAtLogin)
                .labelsHidden()
                .toggleStyle(.switch)
                .onChange(of: opensAtLogin) { _, isOn in
                    OpenAtLogin.set(isOn)
                    opensAtLogin = OpenAtLogin.isEnabled
                }
        case .apps:
            Button { addApps() } label: { Label("Add App…", systemImage: "plus") }.pointerCursor()
            Button { Task { await StartupRoutine.shared.run(apps, locksScreen: false) } } label: {
                Label("Run Now", systemImage: "play.fill")
            }
            .pointerCursor()
            .disabled(apps.isEmpty)
            .help("Open the apps now to test, without locking the screen")
        case .lock:
            Toggle("", isOn: $locksScreen).labelsHidden().toggleStyle(.switch)
        case .awake:
            Toggle("", isOn: $keepsAwake).labelsHidden().toggleStyle(.switch)
        }
    }

    @ViewBuilder private func extra(_ step: StartupStep) -> some View {
        if step == .apps, !apps.isEmpty {
            VStack(spacing: 6) {
                ForEach($apps) { $app in StartupAppRow(app: $app) { apps.removeAll { $0.id == app.id } } }
            }
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

enum StartupStep: Hashable {
    case power, disk, login, app, apps, lock, awake
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
                        .frame(minWidth: 18, maxWidth: isCompact ? 18 : 56)
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
