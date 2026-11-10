import SwiftUI

struct AppTool: Identifiable {
    let page: SidebarPage
    let icon: String
    let title: String
    let summary: String
    let colors: [Color]

    var id: SidebarPage { page }
    var color: Color { colors[0] }
}

enum ToolGroup: String, CaseIterable, Identifiable {
    case clean, system, productivity, media, developer

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var tools: [AppTool] {
        switch self {
        case .clean: [
            AppTool(page: .cleanDisk, icon: "internaldrive.fill", title: "Clean Disk", summary: "Junk, caches and build output", colors: [.teal, .blue]),
            AppTool(page: .largeFiles, icon: "doc.text.magnifyingglass", title: "Large Files", summary: "Biggest files anywhere", colors: [.orange, .pink]),
            AppTool(page: .uninstall, icon: "trash.fill", title: "Uninstall Apps", summary: "Apps and their leftovers", colors: [.red, .orange]),
        ]
        case .system: [
            AppTool(page: .windows, icon: "macwindow.on.rectangle", title: "Windows", summary: "Snap and move windows", colors: [.indigo, .blue]),
            AppTool(page: .input, icon: "computermouse.fill", title: "Mouse & Keyboard", summary: "Scrolling, buttons, ⌘Q guard", colors: [.mint, .blue]),
            AppTool(page: .ram, icon: "memorychip", title: "RAM", summary: "Memory and heavy apps", colors: [.mint, .teal]),
            AppTool(page: .displays, icon: "display.2", title: "Displays", summary: "Monitors and wallpapers", colors: [.purple, .pink]),
            AppTool(page: .portsJobs, icon: "network", title: "Ports & Jobs", summary: "Ports, cron jobs, login items", colors: [.cyan, .blue]),
            AppTool(page: .powerRecovery, icon: "bolt.fill", title: "Power Recovery", summary: "Starts up on its own after a power cut", colors: [.orange, .yellow]),
            AppTool(page: .keepAwake, icon: "cup.and.saucer.fill", title: "Keep Awake", summary: "Stop your Mac from sleeping", colors: [.orange, .brown]),
            AppTool(page: .controls, icon: "switch.2", title: "Quick Controls", summary: "Dark mode, hidden files, lock, eject", colors: [.teal, .blue]),
        ]
        case .productivity: [
            AppTool(page: .clipboard, icon: "doc.on.clipboard.fill", title: "Clipboard", summary: "Copy history on ⌘⇧V", colors: [.indigo, .purple]),
            AppTool(page: .screenRecord, icon: "record.circle", title: "Screen Record", summary: "Screen, sound and mic", colors: [.red, .pink]),
            AppTool(page: .typing, icon: "keyboard", title: "Vietnamese Typing", summary: "Telex, VNI and macros", colors: [.blue, .indigo]),
            AppTool(page: .commandBar, icon: "command", title: "Command Bar", summary: "Launch, calculate, convert", colors: [.indigo, .purple]),
            AppTool(page: .snippets, icon: "text.badge.plus", title: "Snippets", summary: "Short triggers, long text", colors: [.orange, .pink]),
            AppTool(page: .tools, icon: "wrench.and.screwdriver.fill", title: "Tools", summary: "Color picker, text grab", colors: [.teal, .green]),
            AppTool(page: .files, icon: "folder.fill.badge.gearshape", title: "Finder Tools", summary: "Cut and paste, Shelf, installers", colors: [.cyan, .blue]),
        ]
        case .media: [
            AppTool(page: .sound, icon: "speaker.wave.2.fill", title: "Sound", summary: "Switch outputs, mute every mic", colors: [.pink, .orange]),
            AppTool(page: .music, icon: "music.note", title: "Music", summary: "Hi-res and DSD player", colors: [.pink, .purple]),
        ]
        case .developer: [
            AppTool(page: .devTools, icon: "terminal.fill", title: "Dev Tools", summary: "Runtimes and packages", colors: [.green, .teal]),
        ]
        }
    }

    static var allTools: [AppTool] { allCases.flatMap(\.tools) }
}

struct PowerRecoveryView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    Circle()
                        .fill(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: "bolt.fill").font(.system(size: 18)).foregroundStyle(.white))
                        .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Power Recovery").font(.title2).fontWeight(.bold)
                        Text("Your Mac starts up, logs in and reopens your apps on its own after a power cut.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(18)
                .glassCard(cornerRadius: 22)
                StartupSettingsView()
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(cornerRadius: 20)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
