import SwiftUI

struct InputView: View {
    @EnvironmentObject var input: InputController
    private let buttons: [(Int, String)] = [(2, "Middle button"), (3, "Button 4 (side, back)"), (4, "Button 5 (side, forward)"), (5, "Button 6"), (6, "Button 7")]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "computermouse.fill", title: "Mouse & Keyboard", subtitle: "Fix scrolling, map mouse buttons and guard against slips.",
                           colors: [.mint, .blue])
                if !AXIsProcessTrusted() {
                    Label("These tools need Accessibility access for \(AppIdentity.installedName).", systemImage: "lock.shield")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .glassCard(cornerRadius: 18)
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
                    modifierPicker("Zoom in and out while holding", $input.settings.zoomModifier)
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
