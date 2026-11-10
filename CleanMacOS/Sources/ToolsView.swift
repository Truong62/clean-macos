import KeyboardShortcuts
import SwiftUI

struct ToolsView: View {
    @EnvironmentObject var screenTools: ScreenTools
    @EnvironmentObject var camera: CameraPreviewController

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "wrench.and.screwdriver.fill", title: "Tools", subtitle: "Pick colors, grab text, jot notes, check your camera and quit apps.",
                           colors: [.teal, .green])
                CardSection(title: "Color picker", icon: "eyedropper") {
                    HStack {
                        Button { screenTools.pickColor() } label: { Label("Pick a Color", systemImage: "eyedropper.halffull") }
                            .buttonStyle(.borderedProminent)
                        if let last = screenTools.lastColor { Text(last).font(.body.monospaced()).textSelection(.enabled) }
                        Spacer()
                    }
                    Picker("Copy as", selection: $screenTools.settings.colorFormat) {
                        ForEach(PickedColorFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)
                    Toggle("Leave out the # in HEX", isOn: $screenTools.settings.dropsHash).disabled(screenTools.settings.colorFormat != .hex)
                    Toggle("Show mode palette in color picker", isOn: $screenTools.settings.showsColorModes)
                    shortcutRow("Pick a color with a shortcut", isOn: $screenTools.settings.colorShortcut, name: .pickColor)
                }
                CardSection(title: "Grab text", icon: "text.viewfinder") {
                    HStack {
                        Button { screenTools.grabText() } label: { Label("Grab Text from the Screen", systemImage: "text.viewfinder") }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    Text("Drag over any part of the screen. The text is copied, and QR codes are read first.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Read QR and other codes first", isOn: $screenTools.settings.detectsCodes)
                    Toggle("Join lines into one paragraph", isOn: $screenTools.settings.removesLineBreaks)
                    Toggle("Show mode palette in text grab", isOn: $screenTools.settings.showsTextModes)
                    shortcutRow("Grab text with a shortcut", isOn: $screenTools.settings.textShortcut, name: .grabText)
                    Text("Needs Screen Recording access for \(AppIdentity.installedName) to see other apps' windows.").font(.caption).foregroundStyle(.secondary)
                }
                ScratchpadSettingsCard()
                CardSection(title: "Camera preview", icon: "web.camera") {
                    HStack {
                        Button { camera.toggle() } label: { Label(camera.isOpen ? "Hide Camera Preview" : "Show Camera Preview", systemImage: "web.camera") }
                            .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    Text("A small mirrored window at the top of the screen to check how you look. Nothing is recorded, and the camera turns off when it closes.")
                        .font(.caption).foregroundStyle(.secondary)
                    shortcutRow("Show the camera with a shortcut", isOn: $camera.settings.isEnabled, name: .cameraPreview)
                }
                QuitAppsSettingsCard()
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func shortcutRow(_ title: String, isOn: Binding<Bool>, name: KeyboardShortcuts.Name) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: isOn)
            if isOn.wrappedValue {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    KeyboardShortcuts.Recorder(for: name)
                }
            }
        }
    }
}
