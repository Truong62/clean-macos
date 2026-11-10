import AppKit
import KeyboardShortcuts
import SwiftUI

struct PageHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    let colors: [Color]

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: icon).font(.system(size: 18)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2).fontWeight(.bold)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .glassCard(cornerRadius: 22)
    }
}

struct CardSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }
}

struct KeepAwakeView: View {
    @EnvironmentObject var keepAwake: KeepAwake
    @EnvironmentObject var bluetooth: BluetoothSleepGuard
    @State private var untilTime = Date().addingTimeInterval(3600)
    private let hasBattery = PowerState.hasBattery

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "cup.and.saucer.fill", title: "Keep Awake", subtitle: "Stop your Mac and its display from going to sleep.",
                           colors: [.orange, .brown])
                session
                CardSection(title: "Options", icon: "slider.horizontal.3") {
                    Toggle("Keep the display on too", isOn: $keepAwake.settings.keepsDisplayOn)
                    Toggle("Pause while the screen is locked", isOn: $keepAwake.settings.pausesWhenLocked)
                    Toggle(isOn: $keepAwake.settings.nudgesPointer) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Move the pointer a little when idle")
                            Text("Keeps chat apps from showing you as away. Needs Accessibility access.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if hasBattery {
                        Picker("Stop on battery below", selection: $keepAwake.settings.minimumBattery) {
                            Text("Never").tag(Int?.none)
                            ForEach([5, 10, 20, 30], id: \.self) { Text("\($0)%").tag(Int?.some($0)) }
                        }
                        .frame(maxWidth: 320)
                        Toggle(isOn: $keepAwake.settings.closedLid) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Stay awake with the lid closed")
                                Text("macOS asks for your password when this starts and stops.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleKeepAwake)
                    }
                }
                CardSection(title: "Start on its own", icon: "wand.and.stars") {
                    Toggle("When an external display is connected", isOn: $keepAwake.settings.rules.whenExternalDisplay)
                    Toggle("When the Mac is plugged in", isOn: $keepAwake.settings.rules.whenOnPower)
                    AppListEditor(title: "When one of these apps is open", bundleIDs: $keepAwake.settings.rules.apps)
                    Picker("Start when", selection: $keepAwake.settings.rules.requireAll) {
                        Text("Any rule matches").tag(false)
                        Text("All rules match").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
                CardSection(title: "While asleep", icon: "moon.zzz.fill") {
                    Toggle("Turn Bluetooth off while the Mac sleeps", isOn: $bluetooth.isEnabled)
                        .disabled(!bluetooth.isAvailable)
                    Text("It comes back on when the Mac wakes, only if MacKit turned it off.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var session: some View {
        CardSection(title: keepAwake.isActive ? "Awake" : "Start", icon: "timer") {
            if let current = keepAwake.session {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(current.remaining(now: context.date).map { "\(KeepAwakeSession.countdown($0)) left" } ?? "Until you stop it")
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        if keepAwake.isPausedForLock {
                            Text("Paused while the screen is locked").font(.caption).foregroundStyle(.orange)
                        } else if current.isAutomatic {
                            Text("Started by your rules").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    ForEach([900, 1800, 3600], id: \.self) { seconds in
                        Button("+\(seconds < 3600 ? "\(seconds / 60)m" : "1h")") { keepAwake.extend(by: TimeInterval(seconds)) }
                            .disabled(current.ends == nil)
                    }
                    Spacer()
                    Button("Stop", role: .destructive) { keepAwake.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(KeepAwakeDuration.presets, id: \.self) { duration in
                        Button { keepAwake.start(duration) } label: { Text(duration.title).frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                }
                HStack {
                    DatePicker("Until", selection: $untilTime, displayedComponents: .hourAndMinute)
                        .frame(maxWidth: 200)
                    Button("Start") {
                        let target = untilTime > Date() ? untilTime : untilTime.addingTimeInterval(86400)
                        keepAwake.start(.until(target))
                    }
                }
            }
        }
    }
}

struct AppListEditor: View {
    let title: String
    @Binding var bundleIDs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button { add() } label: { Label("Add App", systemImage: "plus") }
            }
            ForEach(bundleIDs, id: \.self) { bundleID in
                HStack {
                    Text(Self.name(for: bundleID)).font(.callout)
                    Text(bundleID).font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button { bundleIDs.removeAll { $0 == bundleID } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    static func name(for bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(bundleID) else { return }
        bundleIDs.append(bundleID)
    }
}
