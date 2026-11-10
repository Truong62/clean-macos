import KeyboardShortcuts
import SwiftUI

struct SwitcherView: View {
    @EnvironmentObject var switcher: SwitcherController
    @State private var ruleBundleID = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "rectangle.stack", title: "App Switcher", subtitle: "Browse windows with the keyboard or preview them above the Dock.", colors: [.indigo, .blue])
                CardSection(title: "App Switcher", icon: "rectangle.stack") {
                    Toggle("Enable App Switcher", isOn: $switcher.settings.isEnabled)
                    Text("Hold to browse, release to switch. Shift or ← goes back; W closes, Q quits, Esc cancels.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Layout", selection: $switcher.settings.layout) {
                        ForEach(SwitcherLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Preview size", selection: $switcher.settings.size) {
                        ForEach(PreviewSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Open on", selection: $switcher.settings.placement) {
                        ForEach(SwitcherPlacement.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Show delay: \(switcher.settings.showDelay) ms", value: $switcher.settings.showDelay, in: 0...500, step: 25)
                    Picker("Columns", selection: $switcher.settings.columns) {
                        Text("Auto").tag(0)
                        ForEach(2...10, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("Instant selection", isOn: $switcher.settings.instantSelection)
                    Toggle("Ignore pointer hover", isOn: $switcher.settings.ignoreHover)
                    Toggle("S pins search until Return", isOn: $switcher.settings.pinSearch)
                    Toggle("Show shortcut hints", isOn: $switcher.settings.shortcutHints)
                    Toggle("One entry per app", isOn: $switcher.settings.onePerApp)
                }
                CardSection(title: "Shortcuts", icon: "keyboard") {
                    KeyboardShortcuts.Recorder("Apps", name: .switcherApps) { switcher.shortcutChanged($0, name: .switcherApps, mode: .apps) }
                    KeyboardShortcuts.Recorder("Current-app windows", name: .switcherCurrentApp) { switcher.shortcutChanged($0, name: .switcherCurrentApp, mode: .currentApp) }
                    KeyboardShortcuts.Recorder("All windows", name: .switcherAllWindows) { switcher.shortcutChanged($0, name: .switcherAllWindows, mode: .allWindows) }
                    Toggle("Enable all-windows shortcut (⌥Tab)", isOn: $switcher.settings.allWindowsEnabled)
                    Toggle("Take over the system switcher shortcuts", isOn: $switcher.settings.takeover)
                        .disabled(!switcher.takeover.available)
                    Text("Takeover applies only while App Switcher is enabled and Accessibility is available. Turning it off restores the native shortcuts.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !switcher.notice.isEmpty { Text(switcher.notice).font(.caption).foregroundStyle(.orange) }
                }
                CardSection(title: "Windows", icon: "macwindow") {
                    Toggle("Current desktop only", isOn: $switcher.settings.currentDesktopOnly)
                    Toggle("Current display only", isOn: $switcher.settings.currentDisplayOnly)
                    Toggle("Hide full-screen windows", isOn: $switcher.settings.hideFullScreen)
                    Toggle("Treat hidden apps as minimized", isOn: $switcher.settings.hiddenAsMinimized)
                    Picker("Minimized windows", selection: $switcher.settings.minimized) {
                        ForEach(MinimizedOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if switcher.settings.takeover {
                        LabeledContent("Apps without windows", value: "All apps · required by takeover")
                    } else {
                        Picker("Apps without windows", selection: $switcher.settings.windowless) {
                            ForEach(WindowlessApps.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    ForEach(switcher.settings.appRules.keys.sorted(), id: \.self) { bundleID in
                        HStack {
                            Text(bundleID).lineLimit(1).truncationMode(.middle)
                            Picker("Rule", selection: Binding(get: { switcher.settings.appRules[bundleID] ?? .windows }, set: { switcher.settings.appRules[bundleID] = $0 })) {
                                ForEach(SwitcherAppRule.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }.labelsHidden()
                            Button { switcher.settings.appRules.removeValue(forKey: bundleID) } label: { Image(systemName: "minus.circle") }.help("Remove rule")
                        }
                    }
                    HStack {
                        TextField("App bundle ID for a window rule", text: $ruleBundleID).textFieldStyle(.roundedBorder)
                        Button("Add rule") {
                            let value = ruleBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { return }
                            switcher.settings.appRules[value] = .windows
                            ruleBundleID = ""
                        }.disabled(ruleBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    TextField("Pause thumbnails for bundle IDs or executable paths, separated by commas", text: listBinding(\.pausedApps))
                        .textFieldStyle(.roundedBorder)
                }
                CardSection(title: "Dock Preview", icon: "dock.rectangle") {
                    Toggle("Enable Dock preview", isOn: $switcher.settings.dockEnabled)
                    if switcher.settings.dockEnabled && !switcher.dockBlocked.isEmpty {
                        Text(switcher.dockBlocked).font(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Current desktop only", isOn: $switcher.settings.dockCurrentDesktopOnly)
                    Stepper("Open delay: \(switcher.settings.dockDelay) ms", value: $switcher.settings.dockDelay, in: 200...900, step: 50)
                    Stepper("Background opacity: \(switcher.settings.dockOpacity)%", value: $switcher.settings.dockOpacity, in: 40...100, step: 5)
                    Picker("Thumbnail size", selection: $switcher.settings.dockSize) {
                        ForEach(PreviewSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Close button quits the app", isOn: $switcher.settings.dockQuitsApp)
                    Toggle("Sort by creation order", isOn: $switcher.settings.dockCreationOrder)
                    TextField("Pause Dock thumbnails for bundle IDs or executable paths, separated by commas", text: listBinding(\.dockPausedApps))
                        .textFieldStyle(.roundedBorder)
                }
                CardSection(title: "Shared previews", icon: "photo.on.rectangle") {
                    Toggle("Minimal previews", isOn: $switcher.settings.minimalPreviews)
                    Text("Thumbnails are kept in memory. Simple list does not capture windows. Dock preview needs both permissions below.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !switcher.accessibility {
                        HStack {
                            Label("Accessibility required", systemImage: "lock.shield")
                            Spacer()
                            Button("Allow Accessibility…") { switcher.requestAccessibility() }
                        }
                    }
                    if !switcher.screenRecording {
                        HStack {
                            Label("Screen Recording enables thumbnails", systemImage: "rectangle.dashed.badge.record")
                            Spacer()
                            Button("Allow Screen Recording…") { switcher.requestScreenRecording() }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func listBinding(_ path: WritableKeyPath<SwitcherSettings, [String]>) -> Binding<String> {
        Binding(get: { switcher.settings[keyPath: path].joined(separator: ", ") }, set: { value in
            switcher.settings[keyPath: path] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        })
    }
}

struct SwitcherPanelView: View {
    @ObservedObject var controller: SwitcherController
    @ObservedObject var thumbnails: SwitcherThumbnails
    let dock: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            if !dock {
                HStack {
                    if controller.session.pinned { Label("Search pinned", systemImage: "pin.fill").font(.caption) }
                    Spacer()
                    Label(controller.session.query.isEmpty ? "\(controller.session.visible.count)/\(controller.session.entries.count)" :
                            "\(controller.session.query) · \(controller.session.visible.count)/\(controller.session.entries.count)", systemImage: "magnifyingglass")
                        .font(.system(size: 12)).lineLimit(1).padding(7).background(.quaternary, in: Capsule())
                }
                .padding(.horizontal, 12).padding(.top, 8)
            }
            if dock { dockCards }
            else if controller.session.visible.isEmpty {
                Text(controller.session.query.isEmpty ? "No windows" : "No results for “\(controller.session.query)”")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if controller.settings.layout == .icons { windowStrip }
                if controller.settings.layout == .list, let selected = controller.session.selected {
                    HStack {
                        icon(selected).frame(width: 24, height: 24)
                        Text(selected.appName).font(.headline)
                        Text("\(controller.selectedAppWindows.count)").font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(controller.selectedAppWindows) { window in
                                    Button(window.displayTitle) { controller.select(window) }
                                        .lineLimit(1).frame(maxWidth: 180 * controller.settings.size.scale)
                                }
                            }
                        }
                    }.padding(10)
                }
                switcherCards
                if controller.settings.shortcutHints && controller.settings.layout != .previews {
                    Text("← → select · Return switch · W close · Q quit · Esc cancel").font(.caption2).foregroundStyle(.secondary).padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: dock ? 18 : 24).fill(Color(nsColor: .windowBackgroundColor)) }
            else { RoundedRectangle(cornerRadius: dock ? 18 : 24).fill(.regularMaterial).opacity(dock ? Double(controller.settings.dockOpacity) / 100 : 1) }
        }
        .overlay(RoundedRectangle(cornerRadius: dock ? 18 : 24).strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var switcherCards: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(controller.grid.card.width), spacing: controller.grid.gap), count: controller.grid.columns), spacing: controller.grid.gap) {
                    ForEach(controller.displayed) { window in
                        if controller.settings.layout == .previews {
                            card(window, picture: CGSize(width: 268 * controller.settings.size.scale, height: 156 * controller.settings.size.scale))
                                .frame(width: controller.grid.card.width, height: controller.grid.card.height)
                                .id(window.id)
                        } else { iconTile(window).id(window.id) }
                    }
                }
                .padding(controller.grid.padding)
            }
            .onChange(of: controller.session.selection) { _, _ in
                guard let selected = controller.session.selected else { return }
                let id = controller.settings.layout == .previews ? selected.id : controller.displayed.first { $0.pid == selected.pid }?.id ?? selected.id
                withAnimation(reduceMotion || controller.settings.instantSelection ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
        }
    }

    private var windowStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(controller.selectedAppWindows) { window in
                    card(window, picture: CGSize(width: 200 * controller.settings.size.scale, height: 116 * controller.settings.size.scale))
                        .frame(width: 220 * controller.settings.size.scale, height: 164 * controller.settings.size.scale)
                }
            }
            .padding(10)
        }
        .frame(height: 184 * controller.settings.size.scale)
    }

    private var dockCards: some View {
        ScrollView(controller.dockGeometry.edge == .bottom ? .horizontal : .vertical, showsIndicators: false) {
            let layout = controller.dockGeometry.edge == .bottom ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
            layout {
                ForEach(controller.dockWindows) { window in
                    card(window, picture: controller.settings.dockSize.dockPicture)
                        .frame(width: controller.settings.dockSize.dockPicture.width + 30, height: controller.settings.dockSize.dockPicture.height + 66)
                }
            }
            .padding(10)
        }
    }

    private func isSelected(_ window: SwitcherWindow) -> Bool {
        dock ? controller.hovered == window.id : controller.session.selected?.id == window.id
    }

    private func card(_ window: SwitcherWindow, picture: CGSize) -> some View {
        let selected = isSelected(window)
        let minimal = controller.settings.minimalPreviews
        return VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.12))
                if let image = thumbnails.images[window.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(5).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    icon(window).frame(width: min(80, picture.width * 0.4), height: min(80, picture.height * 0.6)).opacity(dock ? 0.35 : 1)
                }
                if !minimal {
                    VStack {
                        HStack {
                            if controller.hovered == window.id {
                                Button {
                                    if dock && controller.settings.dockQuitsApp && window.bundleID != "com.apple.finder" { controller.quit(window) }
                                    else { controller.close(window) }
                                } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).help("Close window").disabled(window.isWindowless || controller.closing.contains(window.id))
                                if dock && !window.fullScreen {
                                    Button { controller.minimize(window) } label: { Image(systemName: window.minimized ? "arrow.up.left.and.arrow.down.right.circle.fill" : "minus.circle.fill") }
                                        .buttonStyle(.plain).help(window.minimized ? "Restore window" : "Minimize window")
                                }
                            }
                            Spacer()
                        }
                        Spacer()
                        HStack {
                            if thumbnails.images[window.id] != nil { icon(window).frame(width: 32, height: 32) }
                            Spacer()
                            if window.hidden { badge("eye.slash") }
                            if window.minimized { badge("minus") }
                            if window.fullScreen { badge("arrow.up.left.and.arrow.down.right") }
                            if window.otherDesktop { badge("rectangle.on.rectangle") }
                        }
                    }.padding(6)
                }
            }
            .frame(width: picture.width, height: picture.height)
            if !minimal {
                VStack(spacing: 1) {
                    SwitcherMarquee(title: window.displayTitle, highlighted: selected, hovered: controller.hovered == window.id)
                    if window.isWindowless { Text("No open window").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                    else if window.displayTitle.caseInsensitiveCompare(window.appName) != .orderedSame {
                        Text(window.appName).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(height: 31)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(selected ? 0.14 : 0.03)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected && !minimal ? Color.accentColor : .clear, lineWidth: 2))
        .scaleEffect(selected ? 1 : 0.97)
        .animation(reduceMotion || controller.settings.instantSelection ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: selected)
        .opacity(controller.quitting.contains(window.pid) ? 0.4 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering in
            if hovering {
                controller.hovered = window.id
                if !dock { controller.select(window, hover: true) }
            } else if controller.hovered == window.id { controller.hovered = nil }
        }
        .onTapGesture { controller.commit(window) }
        .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in
            if dock { controller.drag(window) }
        }.onEnded { _ in
            if dock { controller.finishDrag() }
        })
        .contextMenu {
            Button("Open") { controller.commit(window) }
            if !window.fullScreen && !window.isWindowless { Button(window.minimized ? "Restore" : "Minimize") { controller.minimize(window) } }
            if dock { Button("Pin preview") { controller.pin(window) } }
            Button("Close") { controller.close(window) }.disabled(window.isWindowless)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(window.displayTitle + ", " + window.appName)
    }

    private func iconTile(_ window: SwitcherWindow) -> some View {
        let selected = controller.session.selected?.pid == window.pid
        return VStack(spacing: 7) {
            icon(window).frame(width: controller.settings.layout == .icons ? (selected ? 78 : 68) * min(controller.settings.size.scale, 1.15) : 32, height: controller.settings.layout == .icons ? 78 : 32)
            Text(controller.settings.layout == .list ? window.displayTitle : window.appName).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
        }
        .frame(width: controller.grid.card.width, height: controller.grid.card.height)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { if $0 { controller.select(window, hover: true) } }
        .onTapGesture { controller.commit(window) }
    }

    @ViewBuilder private func icon(_ window: SwitcherWindow) -> some View {
        if let image = AppIconCache.image(for: window.bundleID) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
        else { Image(systemName: "app.fill").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary) }
    }

    private func badge(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 10)).frame(width: 22, height: 20).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.white)
    }
}


private struct SwitcherMarquee: View {
    let title: String
    let highlighted: Bool
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()

    var body: some View {
        GeometryReader { geometry in
            let font = NSFont.systemFont(ofSize: 13, weight: highlighted ? .semibold : .regular)
            let width = (title as NSString).size(withAttributes: [.font: font]).width
            if hovered && !reduceMotion && width > geometry.size.width {
                TimelineView(.animation) { timeline in
                    let offset = MarqueeMotion.offset(elapsed: timeline.date.timeIntervalSince(started), width: width)
                    HStack(spacing: 20) {
                        Text(title).fixedSize()
                        Text(title).fixedSize()
                    }
                    .offset(x: -offset)
                }
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: min(0.5, 6 / max(1, geometry.size.width))),
                                             .init(color: .black, location: max(0.5, 1 - 6 / max(1, geometry.size.width))), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            } else { Text(title).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity) }
        }
        .font(.system(size: 13, weight: highlighted ? .semibold : .regular))
        .frame(height: 16)
        .clipped()
        .onChange(of: hovered) { _, _ in started = Date() }
    }
}
