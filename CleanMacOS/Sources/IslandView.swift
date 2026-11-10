import AppKit
import ApplicationServices
import KeyboardShortcuts
import SwiftUI

struct IslandSilhouette: Shape {
    var capsule: Bool
    var neckWidth: CGFloat = 0
    var neckHeight: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        if capsule { return RoundedRectangle(cornerRadius: min(28, rect.height / 2), style: .continuous).path(in: rect) }
        if neckWidth > 0 && rect.width > neckWidth && rect.height > neckHeight + 28 {
            let left = rect.midX - neckWidth / 2
            let right = rect.midX + neckWidth / 2
            var path = Path()
            path.move(to: CGPoint(x: left, y: 0))
            path.addLine(to: CGPoint(x: right, y: 0))
            path.addLine(to: CGPoint(x: right, y: neckHeight))
            path.addLine(to: CGPoint(x: rect.maxX - 28, y: neckHeight))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: neckHeight + 28), control: CGPoint(x: rect.maxX, y: neckHeight))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 28))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - 28, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: 28, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - 28), control: CGPoint(x: 0, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: neckHeight + 28))
            path.addQuadCurve(to: CGPoint(x: 28, y: neckHeight), control: CGPoint(x: 0, y: neckHeight))
            path.addLine(to: CGPoint(x: left, y: neckHeight))
            path.closeSubpath()
            return path
        }
        let shoulder = min(14, rect.height * 0.19)
        let corner = min(28, rect.height * 0.34)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder), control: CGPoint(x: rect.maxX - shoulder, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - corner))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - shoulder - corner, y: rect.maxY), control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + shoulder + corner, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - corner), control: CGPoint(x: rect.minX + shoulder, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.minX + shoulder, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct IslandPanelView: View {
    @ObservedObject var controller: IslandController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTarget = false
    @State private var search = ""
    var capsule: Bool { controller.display?.camera == nil && !controller.settings.simulatedNotch }
    var silhouette: IslandSilhouette {
        IslandSilhouette(capsule: capsule, neckWidth: controller.display?.camera?.width ?? 0,
                         neckHeight: controller.display?.menuHeight ?? 0)
    }
    var top: CGFloat { capsule ? 12 : max(32, controller.display?.camera?.height ?? 24) }

    var body: some View {
        VStack(spacing: 0) {
            if controller.isOpen {
                header
                if controller.exploring { gallery } else {
                    HStack(spacing: 4) {
                        shortcutButtons(controller.settings.leftButtons)
                        IslandSectionView(controller: controller)
                        shortcutButtons(controller.settings.rightButtons)
                    }.padding(.horizontal, 8)
                }
            } else if controller.state.phase == .peek {
                Color.clear.frame(height: capsule ? 8 : top)
                HStack {
                    if controller.state.activities.count > 1 {
                        ForEach(controller.state.activities, id: \.self) { section in
                            Button { controller.state.selectedActivity = section; controller.select(section); controller.open() } label: {
                                Label(section.title, systemImage: section.icon).labelStyle(.iconOnly)
                            }.help(section.title)
                        }
                    } else {
                        Button(controller.section?.title ?? "Explore") { controller.open() }
                    }
                    Spacer()
                    Button { controller.open() } label: { Image(systemName: "chevron.down") }
                }.padding(.horizontal, 28).frame(maxHeight: .infinity)
            } else if controller.state.phase == .drop {
                Color.clear.frame(height: capsule ? 8 : top)
                Label("Shelf ← Drop files → Optimize", systemImage: "tray.and.arrow.down")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5])))
                    .padding(12)
            } else {
                Button { controller.toggle() } label: {
                    HStack(spacing: 8) {
                        if controller.settings.liveBars && controller.state.currentActivity == .music && controller.state.phase != .notice { IslandBarsView(bars: controller.bars) }
                        if controller.state.phase == .notice {
                            Image(systemName: controller.state.notice?.section?.icon ?? "info.circle")
                            Text(controller.state.notice?.title ?? "").lineLimit(1)
                        } else if !capsule && controller.state.phase == .compact && controller.menuRoom.known && min(controller.menuRoom.left, controller.menuRoom.right) >= 44 {
                            Image(systemName: controller.state.currentActivity?.icon ?? "circle").frame(width: 32)
                            Color.clear.frame(width: controller.display?.camera?.width ?? 0)
                            Text(controller.compactReading.isEmpty ? "•••" : controller.compactReading).monospacedDigit().lineLimit(1).frame(width: controller.compactWing)
                        } else if controller.state.phase == .closed, controller.settings.batteryColors.enabled, let charge = controller.batteryPercent {
                            let level = controller.settings.batteryColors.level(percent: Double(charge), plugged: controller.batteryPlugged)
                            Label("\(charge)%", systemImage: "battery.100percent").foregroundStyle(level == .critical ? .red : level == .elevated ? .orange : .white)
                        } else if capsule && controller.state.phase == .compact {
                            Image(systemName: controller.state.currentActivity?.icon ?? "circle")
                            Text(controller.compactReading).monospacedDigit().lineLimit(1)
                        }
                    }
                    .padding(.top, controller.state.phase == .notice && !capsule ? top : 0)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(controller.activityTitle + ". Open Island")
            }
        }
        .padding(.bottom, controller.isOpen ? 16 : 0)
        .foregroundStyle(.white)
        .background(.black)
        .clipShape(silhouette)
        .overlay {
            if controller.settings.outline {
                silhouette.stroke(.white.opacity(0.65), lineWidth: 2)
            }
        }
        .contentShape(silhouette)
        .onHover { controller.hover($0) }
        .onDrop(of: ShelfController.dropTypes, isTargeted: $dropTarget) { providers, location in
            guard controller.settings.sections.contains(.files), controller.context.shelf.settings.isEnabled else { return false }
            guard controller.isOpen || controller.settings.fileDropTarget else { return false }
            let width = controller.display.map { IslandGeometry.frame($0, settings: controller.settings, state: controller.state.phase).width } ?? 340
            let accepted = controller.state.phase == .drop && location.x > width / 2 ? controller.files.accept(providers) : controller.context.shelf.accept(providers)
            if accepted { controller.select(.files); controller.open(hover: true) }
            return accepted
        }
        .contextMenu {
            Button("Explore") { controller.open(); controller.exploring = true }
            Button(controller.state.pinned ? "Unpin" : "Pin") { controller.state.pinned.toggle() }
            Button("Settings") { controller.showSettings() }
            Button("Collapse") { controller.close() }
        }
        .accessibilityAction(named: "Expand") { controller.open() }
        .accessibilityAction(named: "Collapse") { controller.close() }
        .accessibilityAction(named: "Settings") { controller.showSettings() }
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.18), value: controller.exploring)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { controller.exploring.toggle() } label: { Image(systemName: "square.grid.2x2") }.help("Explore (⌘K)")
            if controller.settings.liveBars && controller.section == .music { IslandBarsView(bars: controller.bars, count: 4) }
            Text(controller.exploring ? "Explore" : controller.section?.title ?? "Island").font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            if let notice = controller.state.notice, notice.kind == .level { Text(notice.title).font(.caption).lineLimit(1) }
            Button { controller.state.pinned.toggle() } label: { Image(systemName: controller.state.pinned ? "pin.fill" : "pin") }.help("Pin")
            Button { controller.showSettings() } label: { Image(systemName: "gearshape") }.help("Island settings (⌘,)")
            Button { controller.close() } label: { Image(systemName: "chevron.up") }.help("Collapse")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 28)
        .frame(height: 36)
        .padding(.top, capsule ? 10 : top + 10)
        .padding(.bottom, 12)
    }

    private func shortcutButtons(_ sections: [IslandSection]) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(sections.prefix(3).enumerated()), id: \.offset) { _, section in
                Button { controller.select(section) } label: {
                    Image(systemName: section.icon).frame(width: 44, height: 44).background(.white.opacity(0.08), in: Circle())
                }.buttonStyle(.plain).help(section.title).disabled(!controller.visibleSections.contains(section))
            }
        }
    }

    private var gallery: some View {
        VStack(spacing: 10) {
            TextField("Find a section", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: controller.settings.size == .compact ? 4 : 5), spacing: 8) {
                    ForEach(controller.visibleSections.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { section in
                        Button { controller.select(section) } label: {
                            VStack(spacing: 6) {
                                Image(systemName: section.icon).font(.system(size: 22))
                                Text(section.title).font(.caption).lineLimit(2)
                                Text("⌥⌘" + section.letter.uppercased()).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity).frame(height: 86)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(.horizontal, 28)
    }
}

struct IslandSectionView: View {
    @ObservedObject var controller: IslandController
    var body: some View {
        Group {
            if controller.visibleSections.isEmpty {
                VStack(spacing: 12) {
                    Text("Choose what belongs in your Island").font(.headline)
                    Text("Enable sections in Island settings.").foregroundStyle(.secondary)
                    Button("Settings") { controller.showSettings() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch controller.section {
                case .home: IslandControls(context: controller.context)
                case .mixer:
                    ScrollView { MixerSection().environmentObject(controller.mixer).environmentObject(controller.context.sound) }
                case .captures:
                    if let capture = controller.context.screenTools.screenshot {
                        IslandCaptureView(capture: capture, recorder: capture.recorder, island: controller)
                    }
                case .tools:
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                            ForEach(ToolGroup.allTools) { tool in
                                Button { controller.close(); controller.context.openPage(tool.page) } label: { Label(tool.title, systemImage: tool.icon) }
                            }
                        }
                    }
                case .system: IslandSystemView(monitor: controller.monitor)
                case .music: IslandMusicView(controller: controller, player: controller.music, remote: controller.media)
                case .clipboard: IslandClipboardView(clipboard: controller.context.clipboard, paste: controller.paste)
                case .files: IslandFilesView(shelf: controller.context.shelf, tools: controller.files)
                case .scratchpad: ScratchEditor(controller: controller.context.scratchpad).clipShape(RoundedRectangle(cornerRadius: 12))
                case .timer: IslandTimerView(controller: controller)
                case .calendar: IslandCalendarView(service: controller.calendar)
                case .downloads: IslandDownloadsView(service: controller.downloads, shelf: controller.context.shelf)
                case .camera:
                    if controller.cameraStarted { CameraPreviewView(controller: controller.context.camera) }
                    else {
                        VStack(spacing: 12) {
                            Text("A private camera mirror. Nothing is recorded.").foregroundStyle(.secondary)
                            Button("Start Camera") { controller.startCamera() }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .watch: IslandWatchView(watch: controller.watch, pick: controller.pickWatchArea)
                case .agents: IslandAgentsView(monitor: controller.agents)
                case nil: EmptyView()
                }
            }
        }.padding(.horizontal, 28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IslandControls: View {
    let context: CommandContext
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IslandVolume(sound: context.sound)
                if context.brightness.settings.isEnabled {
                    ForEach(context.brightness.displays) { BrightnessRow(display: $0, isCompact: true) }.environmentObject(context.brightness)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                    ForEach(CommandSources.actions(context).filter { ["keepAwake", "darkMode", "micMute", "cycleOutput"].contains($0.id) }) { item in
                        Button(item.title) { item.run(.none) }
                    }
                }
            }
        }
    }
}

struct IslandVolume: View {
    @ObservedObject var sound: SoundController
    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.2")
            if let volume = sound.outputVolume {
                Slider(value: Binding(get: { volume }, set: { sound.setOutputVolume($0) }), in: 0...1)
                Text("\(Int(volume * 100))%").monospacedDigit().frame(width: 38)
            } else { Text("Volume is controlled by this output device").font(.caption) }
        }
    }
}

struct IslandClipboardView: View {
    @ObservedObject var clipboard: ClipboardViewModel
    var paste: (ClipboardItem) -> Void
    @State private var search = ""
    var body: some View {
        VStack {
            TextField("Search clipboard", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(clipboard.items.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) }) { item in
                        Button { paste(item) } label: { Text(item.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct IslandTimerView: View {
    @ObservedObject var controller: IslandController
    @State private var mode = IslandTimer.Mode.countdown
    @State private var cycle = IslandTimer.Cycle()
    var body: some View {
        VStack(spacing: 12) {
            if controller.timer.active {
                Text(controller.timer.mode == .pomodoro ? "\(controller.timer.phase.rawValue) · Session \(controller.timer.session)" : controller.timer.mode.rawValue.capitalized)
                    .foregroundStyle(.secondary)
                Text(controller.timerText).font(.system(size: 46, weight: .thin, design: .monospaced)).foregroundStyle(.orange)
                HStack {
                    Button("Done") { controller.acknowledgeTimer() }
                    if controller.timer.finished && controller.timer.mode == .pomodoro {
                        Button("Start next phase") { controller.timer.next(now: controller.clock) }
                    } else if !controller.timer.finished {
                        Button(controller.timer.started == nil ? "Resume" : "Pause") {
                            if controller.timer.started == nil { controller.timer.resume(now: controller.clock) }
                            else { controller.timer.pause(now: controller.clock) }
                        }
                    }
                }
            } else {
                Picker("Mode", selection: $mode) { ForEach(IslandTimer.Mode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented)
                if mode == .countdown {
                    Text("\(controller.settings.timerMinutes) min").font(.title)
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(1...180, id: \.self) { minute in
                                Button { controller.settings.timerMinutes = minute } label: {
                                    VStack(spacing: 4) {
                                        Rectangle().fill(controller.settings.timerMinutes == minute ? .orange : .gray).frame(width: 1, height: minute % 5 == 0 ? 28 : 16)
                                        Text(minute == 1 || minute % 5 == 0 ? "\(minute)" : "").font(.system(size: 8)).fixedSize()
                                    }.frame(width: 14, height: 60)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(height: 82)
                }
                if mode == .pomodoro {
                    ScrollView {
                        Stepper("Focus: \(cycle.focus) min", value: $cycle.focus, in: 1...180)
                        Stepper("Short break: \(cycle.shortBreak) min", value: $cycle.shortBreak, in: 1...60)
                        Stepper("Long break: \(cycle.longBreak) min", value: $cycle.longBreak, in: 1...60)
                        Stepper("Long break every \(cycle.every)", value: $cycle.every, in: 1...24)
                        Stepper("Sessions: \(cycle.total)", value: $cycle.total, in: 1...24)
                    }
                }
                Button("Start") { controller.startTimer(mode: mode, cycle: cycle) }.buttonStyle(.borderedProminent)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct IslandCalendarView: View {
    @ObservedObject var service: IslandCalendarService
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !service.status.isEmpty {
                    Text(service.status).foregroundStyle(.secondary)
                    Button("Allow / Refresh Calendar") { service.setEnabled(true, request: true) }
                }
                ForEach(IslandCalendarLogic.groups(service.events, from: Date(), days: 7, calendar: .current), id: \.0) { day, events in
                    if !events.isEmpty {
                        Text(day, format: .dateTime.weekday().month().day()).font(.headline)
                        ForEach(events) { event in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).lineLimit(2)
                                Text(event.allDay ? "All day · \(event.calendar)" : "\(event.start.formatted(date: .omitted, time: .shortened)) · \(event.calendar)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct IslandDownloadsView: View {
    @ObservedObject var service: IslandDownloads
    @ObservedObject var shelf: ShelfController
    var body: some View {
        VStack {
            HStack {
                Text(service.status).font(.caption).lineLimit(1)
                Spacer()
                Button("Choose folder") { service.choose() }
                Button("Forget") { service.forget() }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(service.items) { item in
                        HStack {
                            Image(systemName: item.finished ? "checkmark.circle" : "arrow.down.circle")
                            VStack(alignment: .leading) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                if let fraction = item.fraction {
                                    ProgressView(value: fraction).frame(maxWidth: 160)
                                    Text("\(Int(fraction * 100))%").font(.caption).monospacedDigit()
                                } else { Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if item.finished {
                                Button("Open") { NSWorkspace.shared.open(item.url) }
                                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Button("Shelf") { _ = shelf.accept([NSItemProvider(contentsOf: item.url)].compactMap { $0 }) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct IslandSettingsView: View {
    @EnvironmentObject var island: IslandController
    @State private var tab = "Layout"
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "capsule.fill", title: "Island", subtitle: "Your tools at the top of the display.", colors: [.indigo, .purple])
                CardSection(title: "Island", icon: "capsule") {
                    Toggle("Enable Island", isOn: $island.settings.isEnabled)
                    Text("All sections are optional. Enabling Island does not request access to your camera, calendars or other apps.").font(.caption).foregroundStyle(.secondary)
                    if island.settings.isEnabled { Button("Open Island") { island.open() } }
                }
                Picker("Settings", selection: $tab) { ForEach(["Layout", "Content", "Behavior"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                if tab == "Layout" { layout }
                if tab == "Content" { content }
                if tab == "Behavior" { behavior }
            }.padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private var layout: some View {
        CardSection(title: "Layout", icon: "rectangle.resize") {
            Picker("Size", selection: $island.settings.size) { ForEach(IslandSize.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            if island.settings.size == .custom {
                Slider(value: $island.settings.customWidth, in: 360...600, step: 10) { Text("Width") }
                Slider(value: $island.settings.customHeight, in: 260...640, step: 10) { Text("Height") }
            }
            Button("Allow menu-room measurement…") {
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
            Text("Reads menu-item frames only, to keep Island clear of your menus. Accessibility access is optional.").font(.caption).foregroundStyle(.secondary)
            Toggle("Simulate a hanging notch on external displays", isOn: $island.settings.simulatedNotch)
            Toggle("Outline", isOn: $island.settings.outline)
            if NSScreen.screens.contains(where: { $0.safeAreaInsets.top > 0 }) {
                Slider(value: $island.settings.notchWidth, in: -10...10, step: 1) { Text("Notch width fit") }
                Slider(value: $island.settings.notchHeight, in: -6...6, step: 0.5) { Text("Notch height fit") }
                Toggle("Fill the menu-bar gap", isOn: $island.settings.noGap)
            }
            Slider(value: $island.settings.capsuleWidth, in: -40...40, step: 2) { Text("Capsule width fit") }
            Slider(value: $island.settings.capsuleHeight, in: -4...4, step: 1) { Text("Capsule height fit") }
            Slider(value: $island.settings.capsuleDrop, in: 0...20, step: 1) { Text("Capsule drop") }
        }
    }
    private var content: some View {
        VStack(spacing: 16) {
            CardSection(title: "Sections", icon: "square.grid.2x2") {
                ForEach(IslandSection.allCases) { section in
                    HStack {
                        Toggle(section.title, isOn: Binding(get: { island.settings.sections.contains(section) }, set: { enabled in
                            if enabled { island.settings.sections.append(section) } else { island.settings.sections.removeAll { $0 == section } }
                        }))
                        if let index = island.settings.sections.firstIndex(of: section) {
                            Text("\(index + 1)").foregroundStyle(.secondary)
                            Button { if index > 0 { island.settings.sections.swapAt(index, index - 1) } } label: { Image(systemName: "arrow.up") }.disabled(index == 0)
                            Button { if index + 1 < island.settings.sections.count { island.settings.sections.swapAt(index, index + 1) } } label: { Image(systemName: "arrow.down") }.disabled(index + 1 == island.settings.sections.count)
                        }
                    }
                }
                Text("The camera starts only when you press Start Camera. Calendar access is requested from the Calendar section. Downloads watches only the folder you choose.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CardSection(title: "AI agents", icon: "sparkles") {
                Toggle("Claude Code activity", isOn: $island.settings.claudeActivity)
                Toggle("Codex activity", isOn: $island.settings.codexActivity)
                Toggle("Finished-turn notices", isOn: $island.settings.agentFinishedNotices)
                Picker("Minimum duration", selection: $island.settings.agentMinimumSeconds) {
                    Text("Any").tag(0)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Picker("Activity reading", selection: $island.settings.agentReading) { ForEach(IslandAgentReading.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Toggle("Limit and renewal notices", isOn: $island.settings.agentLimitNotices)
                Stepper("Warn at \(island.settings.agentLimitThreshold)%", value: $island.settings.agentLimitThreshold, in: 50...95)
            }
            CardSection(title: "Music", icon: "music.note") {
                Toggle("Live equalizer bars", isOn: $island.settings.liveBars)
                Text("Captures only the playing app’s audio. Enable this toggle in the current session to allow the system-audio prompt. Reduce Motion disables bars.").font(.caption).foregroundStyle(.secondary)
                Toggle("Lyrics panel", isOn: $island.settings.lyrics)
                Toggle("Online lyrics lookup", isOn: $island.settings.onlineLyrics)
                Text("While Lyrics is open, online lookup sends the song title, artist, album and duration to lrclib.net. If searches return nothing, the artist name is sent to musicbrainz.org for aliases. Imported lyrics stay in memory for this session.").font(.caption).foregroundStyle(.secondary)
                Toggle("Up-next panel", isOn: $island.settings.queue)
                Toggle("Volume row", isOn: $island.settings.musicVolume)
            }
            CardSection(title: "Activities and alerts", icon: "bell") {
                Toggle("Volume and brightness notices", isOn: $island.settings.levelNotices)
                Toggle("Battery notices", isOn: $island.settings.batteryNotices)
                Toggle("Battery warning colors", isOn: $island.settings.batteryColors.enabled)
                if island.settings.batteryColors.enabled {
                    Stepper("Red at \(island.settings.batteryColors.redThreshold)%", value: $island.settings.batteryColors.redThreshold, in: 1...99)
                        .onChange(of: island.settings.batteryColors.redThreshold) { _, value in island.settings.batteryColors.amberThreshold = max(value + 1, island.settings.batteryColors.amberThreshold) }
                    Toggle("Amber warning step", isOn: $island.settings.batteryColors.amber)
                    if island.settings.batteryColors.amber { Stepper("Amber at \(island.settings.batteryColors.amberThreshold)%", value: $island.settings.batteryColors.amberThreshold, in: (island.settings.batteryColors.redThreshold + 1)...100) }
                }
                Toggle("Bluetooth connection notices", isOn: $island.settings.bluetoothNotices)
                Toggle("Calendar countdowns in the final hour", isOn: $island.settings.calendarCountdown)
                Toggle("Timer completion sound", isOn: $island.settings.timerSound)
                Toggle("Screen Watch completion sound", isOn: $island.settings.watchSound)
                Toggle("New-track notices", isOn: $island.settings.trackNotices)
                Toggle("Keep Awake activity", isOn: $island.settings.keepAwakeActivity)
                Toggle("File drag target", isOn: $island.settings.fileDropTarget)
                Text("Notification mirroring is not included. Island does not read Notification Center databases or request Full Disk Access.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var behavior: some View {
        CardSection(title: "Behavior", icon: "hand.tap") {
            Picker("Display", selection: $island.settings.display) { ForEach(IslandDisplayChoice.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Picker("Opening", selection: $island.settings.opening) { ForEach(IslandOpening.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
            Slider(value: $island.settings.activationDelay, in: 0.1...1, step: 0.05) { Text("Hover activation delay") }
            Slider(value: $island.settings.closingDelay, in: 0.1...2, step: 0.05) { Text("Closing delay") }
            Toggle("Toggle with a global shortcut", isOn: $island.settings.shortcut)
            if island.settings.shortcut { KeyboardShortcuts.Recorder(for: .island) }
            if IslandSpace.supportsAbsoluteLevel {
                Toggle("Show on lock screen", isOn: $island.settings.lockScreen)
                Toggle("Lock and unlock sounds", isOn: $island.settings.lockSounds)
            }
            Toggle("Screen Watch shortcut", isOn: $island.settings.watchShortcut)
            if island.settings.watchShortcut { KeyboardShortcuts.Recorder(for: .islandWatch) }
            ForEach([true, false], id: \.self) { left in
                Menu(left ? "Left shortcut buttons" : "Right shortcut buttons") {
                    ForEach(island.visibleSections) { section in
                        Button(section.title) {
                            var buttons = left ? island.settings.leftButtons : island.settings.rightButtons
                            if buttons.contains(section) { buttons.removeAll { $0 == section } }
                            else if buttons.count < 3 { buttons.append(section) }
                            if left { island.settings.leftButtons = buttons } else { island.settings.rightButtons = buttons }
                        }
                    }
                    Button("Clear") { if left { island.settings.leftButtons = [] } else { island.settings.rightButtons = [] } }
                }
            }
            Toggle("Scroll gestures", isOn: $island.settings.gestures)
            Toggle("Haptic feedback", isOn: $island.settings.haptics)
            Toggle("Hide in full screen", isOn: $island.settings.hideInFullScreen)
            Toggle("Allow hover opening in full screen", isOn: $island.settings.fullScreenHover)
            Toggle("Include Island in screenshots and recordings", isOn: $island.settings.includeInCaptures)
        }
    }
}

struct IslandSystemView: View {
    @ObservedObject var monitor: SystemMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(monitor.cpuName).font(.headline)
            LabeledContent("CPU", value: String(format: "%.0f%%", monitor.latestCPU))
            LabeledContent("Memory", value: String(format: "%.0f%%", monitor.memPercent))
            LabeledContent("Disk free", value: ByteCountFormatter.string(fromByteCount: Int64(monitor.diskFree), countStyle: .file))
            LabeledContent("Uptime", value: monitor.uptime)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
