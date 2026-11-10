import SwiftUI
import AppKit
import KeyboardShortcuts
import UniformTypeIdentifiers

struct ScreenshotEditorView: View {
    @ObservedObject var session: ScreenshotEditorSession
    @EnvironmentObject var owner: ScreenshotEditorController
    @State private var showsSettings = false
    @State private var showsBackground = false
    @State private var showsWatermark = false
    @State private var showsCodes = false
    @State private var showsLink = false
    @State private var appeared = false
    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                rail
                Divider()
                ScreenshotCanvas(session: session)
                    .scaleEffect(appeared ? 1 : 0.965)
                    .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { appeared = true } }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { dimensions; options; Spacer(minLength: 4); zoom }
                VStack(spacing: 8) {
                    HStack { dimensions; Spacer(); zoom }
                    options
                }
            }
            .padding(10)
            if !session.status.isEmpty {
                HStack { Text(session.status).font(.caption); Spacer(); Button("Dismiss") { session.status = "" } }.padding(8)
            }
        }
        .background(Color(white: 0.13))
        .preferredColorScheme(.dark)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .popover(isPresented: $showsSettings) { EditorPreferencesView(session: session).environmentObject(owner) }
        .popover(isPresented: $showsBackground) { EditorBackgroundView().environmentObject(owner) }
        .popover(isPresented: $showsWatermark) { EditorWatermarkView().environmentObject(owner) }
        .sheet(isPresented: $showsLink) { EditorLinkView(session: session, controller: session.linkController) }
        .popover(isPresented: $showsCodes) {
            VStack(alignment: .leading, spacing: 12) {
                Text("QR codes").font(.headline)
                ForEach(session.codes, id: \.self) { payload in
                    Text(payload).textSelection(.enabled).lineLimit(5)
                    HStack {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(payload, forType: .string) }
                        if let url = CodeResult(payload: payload).link { Button("Open Link") { NSWorkspace.shared.open(url) } }
                    }
                }
            }.padding(20).frame(width: 340)
        }
    }
    private var topBar: some View {
        HStack(spacing: 12) {
            EditorWindowDragStrip().frame(minWidth: 60)
            Menu {
                Text("\(session.history.past.count) undo steps")
                Button("Undo") { session.undo() }.disabled(session.history.past.isEmpty)
                Button("Redo") { session.undo(true) }.disabled(session.history.future.isEmpty)
            } label: { Image(systemName: "clock.arrow.circlepath") }
            icon("Discard", "trash") { session.discard = true; session.window?.close() }
            icon("Undo", "arrow.uturn.backward") { session.undo() }.disabled(session.history.past.isEmpty)
            icon("Redo", "arrow.uturn.forward") { session.undo(true) }.disabled(session.history.future.isEmpty)
            if !session.codes.isEmpty { icon("QR codes", "qrcode") { showsCodes = true } }
            icon("Pin", "pin") { session.pin() }
            icon("Share", "square.and.arrow.up") { session.share() }
            Menu {
                Button("Create Temporary Link…") { showsLink = true }.disabled(owner.linkService == nil)
                if owner.linkService == nil { Text("No link service configured") }
            } label: { Image(systemName: "link") }.help("Temporary link")
            HStack(spacing: 2) {
                Button("Save") { session.save() }
                Menu {
                    Button("Save As…") { session.save(as: true) }
                    if owner.shelf?.settings.isEnabled == true { Button("Add to Shelf") { session.addToShelf() } }
                } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton)
                .frame(width: 16)
            }
            Button("Copy") { session.copy() }.buttonStyle(.borderedProminent)
        }
        .padding(.trailing, 12)
        .frame(height: 38)
    }
    private var rail: some View {
        GeometryReader { geometry in
            let row: CGFloat = geometry.size.height < 520 ? 23 : 29
            let count = min(owner.settings.toolOrder.count, max(1, Int((geometry.size.height - 64) / (row + 3))))
            VStack(spacing: 3) {
                ForEach(Array(owner.settings.toolOrder.prefix(count).enumerated()), id: \.element) { index, tool in toolButton(tool, index: index, height: row) }
                if count < owner.settings.toolOrder.count {
                    Menu {
                        ForEach(Array(owner.settings.toolOrder.dropFirst(count))) { tool in Button(tool.title) { session.choose(tool) } }
                    } label: { Image(systemName: "ellipsis") }.frame(width: 33, height: row)
                }
                Spacer(minLength: 0)
                icon("Editor Settings", "gearshape") { showsSettings = true }.frame(width: 33, height: 29)
            }.padding(.vertical, 8).frame(maxWidth: .infinity)
        }.frame(width: 49)
    }
    private func toolButton(_ tool: AnnotationTool, index: Int, height: CGFloat) -> some View {
        Button { session.choose(tool) } label: {
            Image(systemName: tool.symbol)
                .frame(width: 33, height: height)
                .background(session.tool == tool ? Color.white.opacity(0.17) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottomTrailing) {
                    Text(index < 9 ? String(index + 1) : owner.settings.customKeys[tool.rawValue] ?? "").font(.system(size: 8)).foregroundStyle(.secondary).padding(2)
                }
        }.help(tool.title).accessibilityLabel(tool.title)
    }
    private var dimensions: some View {
        Text("\(Int(session.document.size.width)) × \(Int(session.document.size.height)) px\(session.document.scale > 1 ? " @\(Int(session.document.scale))x" : "")")
            .font(.caption.monospacedDigit()).padding(.horizontal, 8).padding(.vertical, 5)
            .background(.white.opacity(0.07), in: Capsule())
            .onDrag {
                guard let url = session.tempFile() else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            .help("Drag out a full-resolution image")
    }
    private var zoom: some View {
        Menu {
            Button("Fit") { session.fits = true; session.pan = .zero }
            Button("1:1") { session.fits = false; session.zoom = 1 }
            Button("Zoom In") { session.fits = false; session.zoom = min(3, session.effectiveZoom * 1.25) }
            Button("Zoom Out") { session.fits = false; session.zoom = max(0.05, session.effectiveZoom * 0.8) }
        } label: { Text(session.fits ? "Fit · \(Int(session.effectiveZoom * 100))%" : "\(Int(session.zoom * 100))%") }.fixedSize()
    }
    private var options: some View {
        HStack(spacing: 10) {
            if session.tool == .crop {
                Button("Cancel") { session.choose(.arrow) }
                Button("Crop") { session.applyCrop() }.buttonStyle(.borderedProminent)
            } else if session.tool == .expand {
                Text("Drag an edge to expand").font(.caption)
                Menu("Fill") {
                    Button("White") { owner.settings.expandColor = .swatches[7] }
                    Button("Transparent") { owner.settings.expandColor = EditorColor(red: 0, green: 0, blue: 0, alpha: 0) }
                    ForEach(0..<EditorColor.swatches.count, id: \.self) { index in
                        Button("Color \(index + 1)") { owner.settings.expandColor = .swatches[index] }
                    }
                }
                EditorColorPicker(title: "Custom", color: $owner.settings.expandColor).frame(width: 90)
                Button("Cancel") { session.choose(.arrow) }
            } else {
                styleOptions
                if session.document.marks.count > 1 && session.selection != nil {
                    icon("Send Backward", "square.3.layers.3d.bottom.filled") { session.reorder(-1) }
                    icon("Bring Forward", "square.3.layers.3d.top.filled") { session.reorder(1) }
                }
                Toggle("Shadows", isOn: $owner.settings.shadows).toggleStyle(.checkbox)
                Button("Background") { showsBackground = true }
                Button("Watermark") { showsWatermark = true }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var styleOptions: some View {
        let style = session.selected?.style ?? owner.settings.style
        let tool = session.selected?.tool ?? session.tool
        return HStack(spacing: 6) {
            Menu {
                ForEach(0..<EditorColor.swatches.count, id: \.self) { index in
                    Button { session.restyle { $0.color = .swatches[index] } } label: { Text(["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Black", "White"][index]) }
                }
            } label: { Circle().fill(Color(cgColor: style.color.cgColor)).frame(width: 16, height: 16) }.help("Color")
            Menu("\(Int(style.width)) pt") {
                ForEach([2, 4, 7], id: \.self) { width in Button("\(width) pt") { session.restyle { $0.width = CGFloat(width) } } }
            }.fixedSize()
            if tool == .arrow {
                Menu(style.head.rawValue.capitalized) {
                    ForEach(ArrowHead.allCases, id: \.self) { head in Button(head.rawValue.capitalized) { session.restyle { $0.head = head } } }
                }.fixedSize()
            }
            if tool == .blur {
                Menu(style.redaction.rawValue.capitalized) {
                    ForEach(RedactionMode.allCases, id: \.self) { mode in Button(mode.rawValue.capitalized) { session.restyle { $0.redaction = mode } } }
                }
                Menu("\(style.strength)") {
                    ForEach(1...5, id: \.self) { level in Button("Strength \(level)") { session.restyle { $0.strength = level } } }
                }.frame(width: 30)
                Toggle("Text only", isOn: Binding(get: { style.textOnly }, set: { value in session.restyle { $0.textOnly = value } })).toggleStyle(.checkbox)
            }
            if tool == .text {
                Button("−") { stepFont(-1, current: style.fontSize) }
                Menu("\(Int(style.fontSize)) pt") {
                    ForEach(AnnotationStyle.fontSizes, id: \.self) { size in Button("\(Int(size)) pt") { session.restyle { $0.fontSize = size } } }
                }.fixedSize()
                Button("+") { stepFont(1, current: style.fontSize) }
            }
            if tool == .sticker {
                Menu(style.sticker) {
                    ForEach(AnnotationStyle.stickers, id: \.self) { sticker in Button(sticker) { session.restyle { $0.sticker = sticker } } }
                }.frame(width: 45)
            }
            if tool == .spotlight {
                Slider(value: $owner.settings.dim, in: 0...1, step: 0.05).frame(width: 80)
                Text("\(Int(owner.settings.dim * 100))%").font(.caption)
            }
        }
    }
    private func stepFont(_ offset: Int, current: CGFloat) {
        let index = AnnotationStyle.fontSizes.firstIndex(of: current) ?? 4
        let next = AnnotationStyle.fontSizes[max(0, min(11, index + offset))]
        session.restyle { $0.fontSize = next }
    }
    private func icon(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: 16, minHeight: 22) }.help(title).accessibilityLabel(title)
    }
}

struct EditorWindowDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

struct EditorPreferencesView: View {
    @ObservedObject var session: ScreenshotEditorSession
    @EnvironmentObject var owner: ScreenshotEditorController
    @State private var conflict = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Editor Settings").font(.headline)
                Toggle("Enable tool keys", isOn: $owner.settings.toolKeys)
                Toggle("Enable image file shortcut", isOn: $owner.settings.fileShortcut)
                KeyboardShortcuts.Recorder("Open image file", name: .editImageFile).disabled(!owner.settings.fileShortcut)
                Toggle("Enable clipboard image shortcut", isOn: $owner.settings.clipboardShortcut)
                KeyboardShortcuts.Recorder("Open clipboard image", name: .editClipboardImage).disabled(!owner.settings.clipboardShortcut)
                Divider()
                Text("Tool order and keys").font(.headline)
                ForEach(Array(owner.settings.toolOrder.enumerated()), id: \.element) { index, tool in
                    HStack {
                        Text(tool.title).frame(maxWidth: .infinity, alignment: .leading)
                        EditorKeyRecorder(label: owner.settings.customKeys[tool.rawValue] ?? (index < 9 ? String(index + 1) : "")) { key, externalOwner in
                            assign(key, tool: tool, externalOwner: externalOwner)
                        }.frame(width: 70, height: 24)
                        Button { move(index, -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                        Button { move(index, 1) } label: { Image(systemName: "chevron.down") }.disabled(index == owner.settings.toolOrder.count - 1)
                    }
                }
                if !conflict.isEmpty { Text(conflict).foregroundStyle(.red).font(.caption) }
                Button("Reset Tool Order and Keys") { owner.settings.toolOrder = AnnotationTool.allCases; owner.settings.customKeys = [:] }
                Divider()
                Toggle("Export at 1×", isOn: $owner.settings.export1x)
                TextField("Filename prefix", text: $owner.settings.namePrefix).textFieldStyle(.roundedBorder)
                HStack {
                    Text(owner.settings.exportFolder.isEmpty ? "Ask where to save" : owner.settings.exportFolder).lineLimit(1).truncationMode(.middle)
                    Button("Choose Folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { owner.settings.exportFolder = url.path }
                    }
                }
            }.padding(20)
        }.frame(width: 380, height: 580)
    }
    private func move(_ index: Int, _ offset: Int) { owner.settings.toolOrder.swapAt(index, index + offset) }
    private func assign(_ key: String, tool: AnnotationTool, externalOwner: String?) {
        let external = externalOwner.map { [key: $0] } ?? [:]
        switch EditorKeyMap.assigning(key, to: tool, settings: owner.settings, external: external) {
        case .success(let settings): owner.settings = settings; conflict = ""
        case .failure(let error): conflict = "This key belongs to \(error.owner)."
        }
    }

}

struct EditorBackgroundView: View {
    @EnvironmentObject var owner: ScreenshotEditorController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Background").font(.headline)
            Picker("Style", selection: $owner.settings.background.kind) {
                ForEach(EditorBackground.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                ForEach(0..<EditorBackground.gradients.count, id: \.self) { index in
                    let look = EditorBackground.gradients[index]
                    Button { owner.settings.background = look } label: {
                        RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: [Color(cgColor: look.first.cgColor), Color(cgColor: look.second.cgColor)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 46, height: 32)
                    }.help("Gradient \(index + 1)")
                }
            }
            EditorColorPicker(title: "First color", color: $owner.settings.background.first)
            if owner.settings.background.kind == .gradient { EditorColorPicker(title: "Second color", color: $owner.settings.background.second) }
            HStack {
                Button("Choose Image…") { pickImage { owner.settings.background.image = $0; owner.settings.background.kind = .image } }
                Menu("Wallpaper") {
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                        Button(screen.localizedName) {
                            if let url = NSWorkspace.shared.desktopImageURL(for: screen), let data = try? Data(contentsOf: url) {
                                owner.settings.background.image = data
                                owner.settings.background.kind = .image
                            }
                        }
                    }
                }
            }
            slider("Margin", value: $owner.settings.background.margin)
            slider("Corners", value: $owner.settings.background.corners)
            slider("Blur", value: $owner.settings.background.blur)
            HStack {
                Button("Save Look +") { if owner.settings.savedBackgrounds.count < 12 { owner.settings.savedBackgrounds.append(owner.settings.background) } }.disabled(owner.settings.savedBackgrounds.count >= 12)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(owner.settings.savedBackgrounds.enumerated()), id: \.offset) { index, look in
                            Button("\(index + 1)") { owner.settings.background = look }
                                .contextMenu { Button("Remove Look") { owner.settings.savedBackgrounds.remove(at: index) } }
                        }
                    }
                }

            }
        }.padding(20).frame(width: 350)
    }
    private func slider(_ title: String, value: Binding<CGFloat>) -> some View { HStack { Text(title).frame(width: 60, alignment: .leading); Slider(value: value, in: 0...1) } }
}

struct EditorWatermarkView: View {
    @EnvironmentObject var owner: ScreenshotEditorController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watermark").font(.headline)
            Picker("Type", selection: $owner.settings.watermark.kind) {
                ForEach(EditorWatermark.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }.pickerStyle(.segmented)
            if owner.settings.watermark.kind == .text {
                TextField("Watermark text", text: Binding(get: { owner.settings.watermark.text }, set: { owner.settings.watermark.text = String($0.prefix(120)) })).textFieldStyle(.roundedBorder)
                HStack {
                    ForEach(0..<EditorColor.swatches.count, id: \.self) { index in
                        Button { owner.settings.watermark.color = .swatches[index] } label: {
                            Circle().fill(Color(cgColor: EditorColor.swatches[index].cgColor)).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.white.opacity(owner.settings.watermark.color == .swatches[index] ? 1 : 0), lineWidth: 2))
                        }.help(["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Black", "White"][index])
                    }
                }
            }
            if owner.settings.watermark.kind == .image {
                Button("Choose Image…") { pickImage(limit: 4096) { owner.settings.watermark.image = $0 } }
            }
            HStack {
                Text("Position")
                Spacer()
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(26)), count: 3), spacing: 4) {
                    ForEach(0..<9, id: \.self) { position in
                        Button { owner.settings.watermark.position = position } label: {
                            Image(systemName: owner.settings.watermark.position == position ? "circle.inset.filled" : "circle").frame(width: 22, height: 22)
                        }.help("Position \(position + 1)")
                    }
                }.frame(width: 86)
            }
            HStack { Text("Size").frame(width: 65, alignment: .leading); Slider(value: $owner.settings.watermark.size, in: 0...1) }
            HStack { Text("Opacity").frame(width: 65, alignment: .leading); Slider(value: $owner.settings.watermark.opacity, in: 0.05...1) }
            HStack { Text("Rotation").frame(width: 65, alignment: .leading); Slider(value: $owner.settings.watermark.rotation, in: -90...90); Text("\(Int(owner.settings.watermark.rotation))°") }
            HStack {
                Button("Save Preset +") { if owner.settings.savedWatermarks.count < 12 { owner.settings.savedWatermarks.append(owner.settings.watermark) } }.disabled(owner.settings.savedWatermarks.count >= 12)
                Menu("Saved Presets") {
                    ForEach(Array(owner.settings.savedWatermarks.enumerated()), id: \.offset) { index, watermark in
                        Button("Preset \(index + 1)") { owner.settings.watermark = watermark }
                        Button("Remove Preset \(index + 1)") { owner.settings.savedWatermarks.remove(at: index) }
                    }
                }.disabled(owner.settings.savedWatermarks.isEmpty)
            }
        }.padding(20).frame(width: 350)
    }
}

struct EditorColorPicker: View {
    let title: String
    @Binding var color: EditorColor
    var body: some View {
        ColorPicker(title, selection: Binding(get: { Color(cgColor: color.cgColor) }, set: { value in
            if let rgb = NSColor(value).usingColorSpace(.sRGB) { color = EditorColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent) }
        }), supportsOpacity: false)
    }
}

@MainActor
private func pickImage(limit: CGFloat = 6000, completion: (Data) -> Void) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let image = ScreenshotRenderer.decode(data),
       let resized = ScreenshotRenderer.resized(image, size: EditorGeometry.downscaled(CGSize(width: image.width, height: image.height), limit: limit)), let encoded = ScreenshotRenderer.encode(resized) { completion(encoded) }
}

struct EditorLinkView: View {
    @ObservedObject var session: ScreenshotEditorSession
    @ObservedObject var controller: EditorLinkController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Temporary Link").font(.headline)
            if controller.state.isBusy { ProgressView().controlSize(.small) }
            if let link = controller.state.link {
                Text(link.url.absoluteString).textSelection(.enabled)
                Text("Expires \(link.expiresAt.formatted())").foregroundStyle(.secondary)
                HStack {
                    Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.url.absoluteString, forType: .string) }
                    Button("Delete Link", role: .destructive) {
                        guard let service = session.owner.linkService else { return }
                        Task { await controller.delete(service: service) }
                    }.disabled(controller.state.isBusy)
                }
            }
            if case .failed(let error) = controller.state { Text(error).foregroundStyle(.red) }
            if let error = controller.error { Text(error).foregroundStyle(.red) }
            HStack {
                if controller.state.link == nil && !controller.state.isBusy {
                    Button("Upload Image") {
                        guard let service = session.owner.linkService, let (data, format) = session.exportData() else { return }
                        Task {
                            await controller.upload(data, format: format, service: service)
                            if controller.state.link != nil { session.markSaved() }
                        }
                    }
                }
                Spacer()
                Button("Close") { dismiss() }
            }
        }.padding(24).frame(width: 420)
    }
}
