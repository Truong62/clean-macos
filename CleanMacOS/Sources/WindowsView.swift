import KeyboardShortcuts
import SwiftUI

struct WindowsView: View {
    @EnvironmentObject var windows: WindowManager
    private let groups: [(String, [WindowAction])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Thirds", [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds]),
        ("Whole screen", [.maximize, .center, .restore, .nextDisplay, .previousDisplay]),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "macwindow.on.rectangle", title: "Windows", subtitle: "Snap, move and tidy windows with the keyboard or the mouse.",
                           colors: [.indigo, .blue])
                if !AXIsProcessTrusted() {
                    Label("Window tools need Accessibility access for \(AppIdentity.installedName).", systemImage: "lock.shield")
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .glassCard(cornerRadius: 18)
                }
                CardSection(title: "Keyboard", icon: "keyboard") {
                    Toggle("Use keyboard shortcuts to place windows", isOn: $windows.settings.shortcutsEnabled)
                    Toggle("Pressing Left or Right Half again cycles ½ → ⅔ → ⅓", isOn: $windows.settings.cyclesOnRepeat)
                    HStack {
                        Text("Gap between windows")
                        Slider(value: $windows.settings.gap, in: 0...30, step: 2).frame(maxWidth: 220)
                        Text("\(Int(windows.settings.gap)) pt").monospacedDigit().foregroundStyle(.secondary)
                    }
                    ForEach(groups, id: \.0) { title, actions in
                        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(actions) { action in
                            HStack {
                                Label(action.title, systemImage: action.icon)
                                Spacer()
                                KeyboardShortcuts.Recorder(for: action.shortcut)
                            }
                            .disabled(!windows.settings.shortcutsEnabled)
                        }
                    }
                }
                CardSection(title: "Mouse", icon: "cursorarrow.motionlines") {
                    Toggle("Drag a window to a screen edge or corner to snap it", isOn: $windows.settings.snapsToEdges)
                    Toggle("Hold ⌃⌘ and drag anywhere in a window to move it, add ⇧ to resize", isOn: $windows.settings.dragsWithModifiers)
                    Toggle("The green button fills the screen without a new Space (hold ⌥ for the usual)", isOn: $windows.settings.greenButtonMaximizes)
                    Picker("Clicking the active app in the Dock", selection: $windows.settings.dockClick) {
                        ForEach(DockClickAction.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(maxWidth: 420)
                }
                CardSection(title: "Apps and Spaces", icon: "square.stack.3d.up") {
                    Toggle("Quit an app when its last window closes", isOn: $windows.settings.quitsOnLastWindow)
                    AppListEditor(title: "Keep these apps running", bundleIDs: $windows.settings.quitExceptions)
                        .disabled(!windows.settings.quitsOnLastWindow)
                    Toggle("Keep Spaces in a fixed order", isOn: $windows.settings.fixedSpaceOrder)
                    Text("macOS normally reorders Spaces by recent use. Changing this restarts the Dock.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
