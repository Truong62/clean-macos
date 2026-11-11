import AppKit
import SwiftUI
import KeyboardShortcuts

struct ScreenshotView: View {
    @EnvironmentObject var capture: ScreenshotController
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "viewfinder", title: "Screenshot", subtitle: "Capture an area, a window, a display or a scrolling page.", colors: [.blue, .cyan])
                CardSection(title: "Capture", icon: "camera") {
                    HStack {
                        Button("Capture now") { capture.start() }.buttonStyle(.borderedProminent)
                        Button("Full display") { capture.start(displayOnly: true) }
                        Button("Scrolling") { capture.start(.scrolling) }
                        Button("Recent captures") { capture.showHistory() }
                    }
                    if !ScreenshotHardware.permitted { Text("Screen Recording access is needed. Start a capture to request it.").foregroundStyle(.secondary) }
                    if !capture.status.isEmpty { Text(capture.status).font(.caption) }
                    Picker("Delay", selection: $capture.settings.delay) {
                        Text("Off").tag(0)
                        ForEach([3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    Toggle("Show screenshot tile in the menu panel", isOn: $capture.settings.menuTile)
                    Toggle("Freeze screen during selection", isOn: $capture.settings.freeze)
                    Toggle("Include pointer", isOn: $capture.settings.includePointer)
                    Toggle("Hide MacKit windows", isOn: $capture.settings.hideOwnWindows)
                    Toggle("Highlight windows under the pointer", isOn: $capture.settings.highlightWindows)
                    Toggle("Show previous area", isOn: $capture.settings.showPreviousArea)
                    Toggle("Show mode palette", isOn: $capture.settings.showModes)
                    Toggle("Automatically scroll", isOn: $capture.settings.automaticScroll)
                        .onChange(of: capture.settings.automaticScroll) { _, enabled in
                            if enabled && !AXIsProcessTrusted() {
                                PasteService.requestAccessibility()
                                if !AXIsProcessTrusted() { capture.settings.automaticScroll = false }
                            }
                        }
                }
                CardSection(title: "After capture", icon: "photo") {
                    Picker("Action", selection: $capture.settings.action) {
                        Text("Ask each time").tag(CaptureAction.ask)
                        Text("Save").tag(CaptureAction.save)
                        Text("Save & Copy").tag(CaptureAction.saveAndCopy)
                        Text("Copy").tag(CaptureAction.copy)
                        Text("Edit").tag(CaptureAction.edit)
                    }
                    Toggle("Automatically copy", isOn: $capture.settings.autoCopy)
                    Toggle("Copy image only", isOn: $capture.settings.imageOnly)
                    Toggle("Save and copy at 1×", isOn: $capture.settings.saveAt1x)
                    Toggle("Add to Shelf when enabled", isOn: $capture.settings.autoShelf)
                    Toggle("Show confirmation preview", isOn: $capture.settings.confirmationPreview)
                    Toggle("Preview takes keyboard focus", isOn: $capture.settings.previewTakesFocus)
                    Picker("Confirmation duration", selection: $capture.settings.confirmationSeconds) {
                        Text("Until dismissed").tag(0)
                        ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    Picker("Preview position", selection: $capture.settings.corner) {
                        ForEach(CaptureCorner.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                CardSection(title: "Files", icon: "folder") {
                    HStack {
                        Text(capture.settings.folder.isEmpty ? "Desktop" : capture.settings.folder).lineLimit(1)
                        Spacer()
                        Button("Choose folder…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { capture.settings.folder = url.path }
                        }
                        Button("Reset") { capture.settings.folder = "" }
                    }
                    TextField("Subfolder pattern", text: $capture.settings.subfolder)
                    TextField("Filename pattern (empty uses macOS style)", text: $capture.settings.pattern)
                    Text("Tokens: {yyyy}, {yy}, {MMMM}, {MM}, {dd}, {HH}, {mm}, {ss}, {nnn} counter").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Stepper("Counter: \(capture.settings.counter)", value: $capture.settings.counter, in: 0...999_999)
                        Button("Reset counter") { capture.settings.counter = 1 }
                    }
                    Text(CaptureNames.filename(pattern: capture.settings.pattern, date: Date(), counter: capture.settings.counter)).font(.caption.monospaced())
                }
                CardSection(title: "Magnifier", icon: "plus.magnifyingglass") {
                    Toggle("Start with magnifier", isOn: $capture.settings.magnifier)
                    Toggle("Remember zoom", isOn: $capture.settings.rememberZoom)
                    Toggle("Use stepped zoom", isOn: $capture.settings.stepZoom)
                    Picker("Default zoom", selection: $capture.settings.zoom) {
                        ForEach([0.5, 1, 2, 4], id: \.self) { Text("\($0, specifier: "%.1f")×").tag($0) }
                    }
                }
                CardSection(title: "Global shortcuts", icon: "keyboard") {
                    shortcut("Area or window", enabled: $capture.settings.areaShortcut, name: .captureArea)
                    shortcut("Scrolling", enabled: $capture.settings.scrollingShortcut, name: .captureScroll)
                    shortcut("Full display", enabled: $capture.settings.displayShortcut, name: .captureDisplay)
                    shortcut("Edit latest", enabled: $capture.settings.latestShortcut, name: .captureLatest)
                    shortcut("Edit clipboard image", enabled: $capture.settings.clipboardShortcut, name: .captureClipboard)
                    shortcut("Recent captures", enabled: $capture.settings.historyShortcut, name: .captureHistory)
                }
                CardSection(title: "Temporary links", icon: "link") {
                    Text("A private HTTPS upload backend is required. No images are uploaded automatically.").font(.caption).foregroundStyle(.secondary)
                    TextField("HTTPS backend", text: $capture.settings.backend)
                    Toggle("Allow temporary links", isOn: $capture.settings.allowLinks)
                    Picker("Expiry", selection: $capture.settings.linkHours) {
                        ForEach([1, 6, 24], id: \.self) { Text("\($0) hours").tag($0) }
                    }
                    shortcut("Upload latest", enabled: $capture.settings.uploadShortcut, name: .captureUpload)
                    ForEach(capture.links) { link in
                        HStack {
                            Text(link.url.absoluteString).lineLimit(1)
                            Button("Copy") { ScreenTools.copy(link.url.absoluteString) }
                            Button("Open") { NSWorkspace.shared.open(link.url) }
                            Button("Delete", role: .destructive) { capture.deleteLink(link) }
                        }
                    }
                }
            }.padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private func controllerShortcutChanged(_ name: KeyboardShortcuts.Name) { capture.validateShortcut(name) }

    private func shortcut(_ title: String, enabled: Binding<Bool>, name: KeyboardShortcuts.Name) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Toggle(title, isOn: enabled)
                Spacer()
                if enabled.wrappedValue { KeyboardShortcuts.Recorder(for: name) { _ in controllerShortcutChanged(name) } }
            }
            if enabled.wrappedValue, let warning = capture.shortcutWarnings[name] {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct CapturePreview: View {
    @ObservedObject var controller: ScreenshotController
    let url: URL
    let scale: CGFloat
    let seconds: Int
    @State private var code: CodeResult?
    var body: some View {
        VStack(spacing: 10) {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 320, height: 138)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .onTapGesture { ScreenshotEditorBridge.open(url); controller.closePreview() }
                    .onDrag { NSItemProvider(contentsOf: controller.dragURL(url, scale: scale) ?? url) ?? NSItemProvider() }
            }
            HStack(spacing: 12) {
                Button { controller.discard(url) } label: { Image(systemName: "trash") }.help("Discard")
                Button("Save") { if controller.save(url, scale: scale) { controller.closePreview() } }.keyboardShortcut("s").disabled(controller.wasSaved(url))
                Button("Copy") { controller.copy(url, scale: scale); controller.closePreview() }.keyboardShortcut("c").disabled(controller.wasCopied(url))
                Button("Edit") { ScreenshotEditorBridge.open(url); controller.closePreview() }.keyboardShortcut(.defaultAction)
                Button { controller.pin(url, scale: scale) } label: { Image(systemName: "pin") }.help("Pin")
                Button { controller.closePreview() } label: { Image(systemName: "xmark") }.keyboardShortcut(.cancelAction)
            }.controlSize(.small)
            HStack {
                Button("Copy text") { if let image = TextRecognizer.image(at: url) { controller.screenTools.recognize(image) } }
                if controller.settings.allowLinks { Button(controller.uploading ? "Uploading…" : "Link") { controller.upload(url, scale: scale) }.disabled(controller.uploading) }
                Button { controller.share(url, scale: scale) } label: { Image(systemName: "square.and.arrow.up") }
                if let code { Button("QR") { controller.screenTools.presentCode(code) } }
                Spacer()
            }.controlSize(.small)
        }
        .padding(15).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .focusable()
        .onKeyPress { key in
            if key.key == .delete || key.key == .deleteForward { controller.discard(url); return .handled }
            if key.characters.lowercased() == "e" { ScreenshotEditorBridge.open(url); controller.closePreview(); return .handled }
            if key.modifiers.contains(.command), key.characters == "w" { controller.closePreview(); return .handled }
            return .ignored
        }
        .onHover { if $0 { controller.pausePreview() } else { controller.resumePreview(seconds: seconds) } }
        .task {
            guard let image = TextRecognizer.image(at: url) else { return }
            let result = await Task.detached { TextRecognizer.recognize(image, detectsCodes: true, removesLineBreaks: false) }.value
            if case .code(let found) = result { code = found }
        }
    }
}

struct CaptureHistoryView: View {
    @ObservedObject var controller: ScreenshotController
    let close: () -> Void
    @State private var confirmsClear = false
    var body: some View {
        VStack {
            HStack {
                Text("Recent captures").font(.headline)
                Spacer()
                Button("Clear…") { confirmsClear = true }.disabled(controller.history.isEmpty)
                Button("Close", action: close).keyboardShortcut(.cancelAction)
            }
            if controller.history.isEmpty { ContentUnavailableView("No captures yet", systemImage: "photo") }
            ScrollView {
                LazyVStack {
                    ForEach(controller.history) { item in
                        HStack {
                            if let image = NSImage(contentsOf: controller.thumbnailURL(for: controller.historyURL(item))) ?? NSImage(contentsOf: controller.historyURL(item)) {
                                Image(nsImage: image).resizable().scaledToFit().frame(width: 104, height: 68)
                            }
                            VStack(alignment: .leading) {
                                Text(item.kind == .screenshot ? "Screenshot" : "Recording")
                                Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { controller.restore(item) }
                            Button { controller.discard(controller.historyURL(item)) } label: { Image(systemName: "trash") }
                        }
                    }
                }
            }.frame(maxHeight: 300)
        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .confirmationDialog("Clear recent captures?", isPresented: $confirmsClear) {
                Button("Clear captures", role: .destructive) { for item in controller.history { controller.discard(controller.historyURL(item)) } }
            }
    }
}

struct CapturePin: View {
    let controller: ScreenshotController
    let panel: NSPanel
    let url: URL
    let scale: CGFloat
    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.gray, lineWidth: 1))
        .onTapGesture(count: 2) { panel.orderOut(nil) }
        .contextMenu {
            Button("Copy") { controller.copy(url, scale: scale) }
            Button("Save As…") { controller.save(url, scale: scale, choose: true) }
            ForEach([100, 85, 70, 50], id: \.self) { opacity in
                Button("Opacity \(opacity)%") { panel.alphaValue = Double(opacity) / 100 }
            }
            Button("Close") { panel.orderOut(nil) }
            Button("Ignore clicks (Option-click to restore)") { controller.ignorePinClicks(panel) }
            Button("Close all") { controller.closePins() }
        }
        .onKeyPress(.escape) { panel.orderOut(nil); return .handled }
        .onKeyPress { press in
            if press.modifiers.contains(.command), press.characters == "c" { controller.copy(url, scale: scale); return .handled }
            if press.modifiers.contains(.command), press.characters == "w" { panel.orderOut(nil); return .handled }
            let step: CGFloat = press.modifiers.contains(.shift) ? 12 : 1
            var origin = panel.frame.origin
            switch press.key {
            case .leftArrow: origin.x -= step
            case .rightArrow: origin.x += step
            case .upArrow: origin.y += step
            case .downArrow: origin.y -= step
            default: return .ignored
            }
            panel.setFrameOrigin(origin)
            return .handled
        }
        .focusable()
    }
}

struct CaptureScrollProgress: View {
    @ObservedObject var controller: ScreenshotController
    var body: some View {
        VStack(spacing: 12) {
            Text("Scroll the selected region · \(controller.scrollHeight) px").font(.headline)
            HStack {
                Button("Cancel") { controller.finishScroll(cancel: true) }.keyboardShortcut(.cancelAction)
                Button("Done") { controller.finishScroll(cancel: false) }.keyboardShortcut(.defaultAction)
            }
        }.padding(16).frame(width: 380, height: 100).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CaptureCountdown: View {
    let value: Int
    let total: Int
    @State private var remaining = 1.0
    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().trim(from: 0, to: remaining).stroke(.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).padding(4)
            Text("\(value)").font(.system(size: 36, weight: .semibold, design: .rounded))
        }.frame(width: 82, height: 82)
            .onAppear { withAnimation(.linear(duration: 1)) { remaining = 0 } }
            .id(value)
    }
}

struct CapturePermissionGuide: View {
    let close: () -> Void
    @State private var granted = false
    @State private var canReset = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(granted ? "Screen Recording allowed" : "Allow Screen Recording").font(.headline)
            Text("1. Open Privacy & Security.\n2. Enable MacKit under Screen Recording.\n3. Relaunch MacKit if macOS asks.")
            HStack {
                Button("System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                if granted {
                    Button("Relaunch") {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.createsNewApplicationInstance = true
                        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                            if error == nil { DispatchQueue.main.async { NSApp.terminate(nil) } }
                        }
                    }
                } else if canReset {
                    Button("Reset and retry") {
                        guard let id = Bundle.main.bundleIdentifier else { return }
                        Task {
                            _ = await Task.detached { CommandRunner.run("/usr/bin/tccutil", ["reset", "ScreenCapture", id]) }.value
                            _ = CGRequestScreenCaptureAccess()
                        }
                    }
                }
            }
            Button("Close", action: close)
        }.padding(20).frame(width: 350, height: 250).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .task {
                for second in 0..<300 {
                    granted = ScreenshotHardware.permitted
                    canReset = second >= 12
                    if granted { break }
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
            }
    }
}

@MainActor
final class CaptureSharingDelegate: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if let service { service.delegate = self } else { completion(false) }
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { completion(true) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { completion(false) }
}
