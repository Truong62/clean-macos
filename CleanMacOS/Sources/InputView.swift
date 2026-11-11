import SwiftUI
import KeyboardShortcuts

struct InputView: View {
    @EnvironmentObject var input: InputController
    @EnvironmentObject var mouseTools: MouseToolsController
    @EnvironmentObject var pointer: PointerAccelerationController
    @EnvironmentObject var trackpadMiddle: TrackpadMiddleController
    private let buttons: [(Int, String)] = [(2, "Middle button"), (3, "Button 4 (side, back)"), (4, "Button 5 (side, forward)"), (5, "Button 6"), (6, "Button 7")]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "computermouse.fill", title: "Mouse & Keyboard", subtitle: "Fix scrolling, map mouse buttons and guard against slips.",
                           colors: [.mint, .blue])
                if !AXIsProcessTrusted() {
                    AccessibilityNotice(text: "These tools need Accessibility access for \(AppIdentity.installedName).")
                }
                CardSection(title: "Scrolling with a mouse wheel", icon: "scroll") {
                    Text("These change mouse wheels only. Trackpads are left alone.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Reverse vertical scrolling", isOn: $input.settings.invertVertical)
                    Toggle("Reverse horizontal scrolling", isOn: $input.settings.invertHorizontal)
                    Toggle("Smooth scrolling", isOn: $input.settings.smoothScroll)
                    Stepper(value: $input.settings.linearLines, in: 0...10) {
                        Text(input.settings.linearLines == 0 ? "Each notch scrolls: system default" : "Each notch scrolls \(input.settings.linearLines) lines")
                    }
                    modifierPicker("Scroll sideways while holding", $input.settings.sidewaysModifier)
                    modifierPicker("Scroll faster while holding", $input.settings.fastModifier)
                    if input.settings.fastModifier != .none {
                        HStack {
                            Text("Faster by")
                            Slider(value: $input.settings.fastMultiplier, in: 2...15, step: 1).frame(maxWidth: 220)
                            Text("\(Int(input.settings.fastMultiplier))×").monospacedDigit()
                        }
                    }
                    Toggle("Pinch zoom with the wheel", isOn: $input.settings.wheelPinch)
                        .onChange(of: input.settings.wheelPinch) { _, enabled in
                            if enabled { PasteService.requestAccessibility() }
                        }
                    Picker("Pinch modifier", selection: $input.settings.pinchModifier) {
                        Text("None (inactive)").tag(ModifierChoice.none)
                        Text("⌥ Option").tag(ModifierChoice.option)
                        Text("⌃ Control").tag(ModifierChoice.control)
                        Text("⌘ Command").tag(ModifierChoice.command)
                    }.disabled(!input.settings.wheelPinch)
                    Text("Control-wheel replaces macOS screen zoom. Hold only the selected modifier.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Trackpad middle click", icon: "hand.point.up.left") {
                    Toggle("Three-finger press sends a middle click", isOn: $trackpadMiddle.settings.pressEnabled)
                        .onChange(of: trackpadMiddle.settings.pressEnabled) { _, enabled in if enabled { trackpadMiddle.requestPermission() } }
                    Picker("Light tap", selection: $trackpadMiddle.settings.tapFingers) {
                        Text("Off").tag(0)
                        Text("3 fingers").tag(3)
                        Text("4 fingers").tag(4)
                    }.onChange(of: trackpadMiddle.settings.tapFingers) { _, count in if count != 0 { trackpadMiddle.requestPermission() } }
                    Text("With three-finger drag enabled, press with four fingers; three-finger light taps are disabled. Requires trackpad touch data.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status = trackpadMiddle.status { Text(status).font(.caption).foregroundStyle(.orange) }
                    AppListEditor(title: "Keep normal trackpad clicks in these apps", bundleIDs: $trackpadMiddle.settings.excludedApps)
                }
                CardSection(title: "Pointer acceleration", icon: "cursorarrow") {
                    Toggle("Turn off mouse pointer acceleration", isOn: $pointer.settings.accelerationOff)
                    Text("Changes connected mice only. Original values are restored when disabled, asleep, signed out or quitting.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status = pointer.status { Text(status).font(.caption).foregroundStyle(.orange) }
                }
                CardSection(title: "Mouse shortcuts and Spaces", icon: "computermouse") {
                    Toggle("Mouse button shortcuts", isOn: $mouseTools.settings.shortcutsEnabled)
                        .onChange(of: mouseTools.settings.shortcutsEnabled) { _, enabled in if enabled { mouseTools.enablePermission() } }
                    ForEach(mouseTools.settings.shortcuts) { shortcut in
                        HStack {
                            Text(MouseShortcut.title(shortcut.button))
                            Text(KeyboardShortcuts.Shortcut(KeyboardShortcuts.Key(rawValue: Int(shortcut.key)),
                                                           modifiers: NSEvent.ModifierFlags(rawValue: UInt(shortcut.flags))).description).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { mouseTools.settings.shortcuts.removeAll { $0.id == shortcut.id } }
                        }
                    }
                    Button("Add Button Shortcut…") { mouseTools.capture(spaces: false) }.disabled(!mouseTools.settings.shortcutsEnabled)
                    Toggle("Hold a mouse button to drag between Spaces", isOn: $mouseTools.settings.spacesEnabled)
                        .onChange(of: mouseTools.settings.spacesEnabled) { _, enabled in if enabled { mouseTools.enablePermission() } }
                    if mouseTools.settings.spacesEnabled {
                        Button(mouseTools.settings.spacesButton.map(MouseShortcut.title) ?? "Choose Drag Button…") { mouseTools.capture(spaces: true) }
                        Toggle("Natural horizontal direction", isOn: $mouseTools.settings.naturalSpaces)
                        if mouseTools.allSpacesHotkeysOff { Text("Enable Spaces and Mission Control keyboard shortcuts in System Settings.").foregroundStyle(.orange) }
                    }
                    if let message = mouseTools.captureMessage {
                        Text(message).font(.caption)
                        Button("Cancel Capture") { mouseTools.cancelCapture() }
                    }
                }
                CardSection(title: "Mouse buttons", icon: "computermouse") {
                    ForEach(buttons, id: \.0) { number, title in
                        Picker(title, selection: Binding(get: { input.settings.buttonActions[number] }, set: { input.settings.buttonActions[number] = $0 })) {
                            Text("Do nothing extra").tag(MouseButtonAction?.none)
                            ForEach(MouseButtonAction.allCases) { Text($0.title).tag(MouseButtonAction?.some($0)) }
                        }
                        .frame(maxWidth: 420)
                    }
                }
                CardSection(title: "Double presses from worn switches", icon: "hand.tap") {
                    debouncePicker("Ignore a click this soon after the last one", $input.settings.clickDebounceMs, [0, 15, 25, 50, 100])
                    debouncePicker("Ignore a key press this soon after the last one", $input.settings.keyDebounceMs, [0, 5, 10, 25, 50, 100])
                }
                CardSection(title: "Quit and close protection", icon: "hand.raised.fill") {
                    Picker("⌘Q", selection: $input.settings.quitProtection) { ForEach(QuitGuard.Mode.allCases) { Text($0.title).tag($0) } }
                        .frame(maxWidth: 320)
                    Picker("⌘W", selection: $input.settings.closeProtection) { ForEach(QuitGuard.Mode.allCases) { Text($0.title).tag($0) } }
                        .frame(maxWidth: 320)
                }
                CardSection(title: "Focus follows the mouse", icon: "scope") {
                    Toggle("Activate the window under the pointer", isOn: $input.settings.focusFollowsMouse)
                    HStack {
                        Text("After")
                        Slider(value: Binding(get: { Double(input.settings.focusDelayMs) }, set: { input.settings.focusDelayMs = Int($0) }), in: 100...3000, step: 50)
                            .frame(maxWidth: 220)
                        Text("\(input.settings.focusDelayMs) ms").monospacedDigit()
                    }
                    .disabled(!input.settings.focusFollowsMouse)
                    Toggle("Also bring the window to the front", isOn: $input.settings.raisesOnFocus).disabled(!input.settings.focusFollowsMouse)
                }
                CardSection(title: "Hyper key", icon: "capslock.fill") {
                    Toggle("Caps Lock works as ⌃⌥⇧⌘ while held", isOn: $input.settings.hyperKey)
                    Toggle("A quick tap of Caps Lock sends Esc", isOn: $input.settings.hyperTapsEscape).disabled(!input.settings.hyperKey)
                    Text("Uses macOS key remapping. It replaces other custom remaps made with hidutil and is undone when MacKit quits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CardSection(title: "Leave these apps alone", icon: "app.dashed") {
                    AppListEditor(title: "Apps that keep their normal mouse and keys", bundleIDs: $input.settings.excludedApps)
                }
                CardSection(title: "Cleaning Mode", icon: "sparkles") {
                    HStack {
                        Text("Lock the keyboard, scrolling and media keys while you wipe them.")
                        Spacer()
                        Button("Start") { input.startCleaning() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func modifierPicker(_ title: String, _ selection: Binding<ModifierChoice>) -> some View {
        Picker(title, selection: selection) { ForEach(ModifierChoice.allCases) { Text($0.title).tag($0) } }
            .frame(maxWidth: 420)
    }

    private func debouncePicker(_ title: String, _ selection: Binding<Int>, _ values: [Int]) -> some View {
        Picker(title, selection: selection) {
            ForEach(values, id: \.self) { Text($0 == 0 ? "Off" : "\($0) ms").tag($0) }
        }
        .frame(maxWidth: 480)
    }
}
