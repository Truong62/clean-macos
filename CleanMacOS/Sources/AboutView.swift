import SwiftUI

struct AboutView: View {
    @EnvironmentObject var updater: UpdaterViewModel
    let navigate: (SidebarPage) -> Void
    @State private var downloads: Int?

    private static let repoURL = URL(string: "https://github.com/Truong62/clean-macos")!
    private static let tools: [(SidebarPage, String, String, String, [Color])] = [
        (.cleanDisk, "internaldrive.fill", "Clean Disk", "Junk, caches and build output", [.teal, .blue]),
        (.largeFiles, "doc.text.magnifyingglass", "Large Files", "Biggest files anywhere", [.orange, .pink]),
        (.uninstall, "trash.fill", "Uninstall Apps", "Apps and their leftovers", [.red, .orange]),
        (.clipboard, "doc.on.clipboard.fill", "Clipboard", "Copy history on ⌘⇧V", [.indigo, .purple]),
        (.jira, "checklist", "Jira", "Your sprint, Notion-style", [.blue, .cyan]),
        (.displays, "display.2", "Displays", "Monitors and wallpapers", [.purple, .pink]),
        (.ram, "memorychip", "RAM", "Memory and heavy apps", [.mint, .teal]),
        (.portsJobs, "network", "Ports & Jobs", "Ports, cron jobs, login items", [.cyan, .blue]),
        (.devTools, "terminal.fill", "Dev Tools", "Runtimes and packages", [.green, .teal]),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero.homeAppear(0)
                toolsSection.homeAppear(1)
                linksSection.homeAppear(2)
                footer.homeAppear(3)
            }
            .padding(24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(AuroraBackground())
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: Color(red: 0.55, green: 0.40, blue: 0.95).opacity(0.45), radius: 28, y: 12)
            VStack(spacing: 6) {
                Text("Clean macOS")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Version \(appVersion) · Build \(buildNumber)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                pill("Free & open source", icon: "heart.fill", color: .pink)
                if let downloads {
                    pill("\(downloads.formatted()) downloads", icon: "arrow.down.circle.fill", color: .blue)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: downloads)
            .task { downloads = await DownloadStats.fetch() }
            Text("A calm, native toolkit that keeps your Mac clean and your dev setup in check. Nothing leaves your Mac — no account, no tracking.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 10) {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!updater.canCheckForUpdates)
                .pointerCursor()
                Button {
                    NSWorkspace.shared.open(Self.repoURL)
                } label: {
                    Label("Star on GitHub", systemImage: "star.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .pointerCursor()
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .homeCard(cornerRadius: 28)
    }

    private func pill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("EVERYTHING IN ONE APP")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                ForEach(Self.tools, id: \.2) { page, icon, title, detail, colors in
                    ToolTile(icon: icon, title: title, stat: detail, colors: colors) { navigate(page) }
                }
            }
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("LINKS")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                LinkRow(title: "Website", subtitle: "truong62.github.io/clean-macos", icon: "globe", color: .blue,
                        url: "https://truong62.github.io/clean-macos/")
                LinkRow(title: "Source Code", subtitle: "github.com/Truong62/clean-macos", icon: "chevron.left.forwardslash.chevron.right",
                        color: .purple, url: Self.repoURL.absoluteString)
                LinkRow(title: "Report an Issue", subtitle: "Open a GitHub issue", icon: "ladybug", color: .red,
                        url: "https://github.com/Truong62/clean-macos/issues")
                LinkRow(title: "Release Notes", subtitle: "Every version on GitHub", icon: "clock.arrow.circlepath", color: .orange,
                        url: "https://github.com/Truong62/clean-macos/releases")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("Made with")
                Image(systemName: "heart.fill").foregroundStyle(.pink)
                Text("by")
                Link("Ngoc Truong", destination: URL(string: "https://ngoctruong.click")!).pointerCursor()
            }
            Text("Swift 6 · SwiftUI · Sparkle  —  \(systemDescription)")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .tracking(1)
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var systemDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let chip = "Apple Silicon"
        #else
        let chip = "Intel"
        #endif
        return "macOS \(version.majorVersion).\(version.minorVersion) · \(chip)"
    }
}

// MARK: - Link Row

struct LinkRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    var url: String? = nil

    @State private var hovered = false

    var body: some View {
        Button {
            if let url, let link = URL(string: url) {
                NSWorkspace.shared.open(link)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(color.gradient)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: .black.opacity(hovered ? 0.12 : 0.04),
                    radius: hovered ? 12 : 6, y: hovered ? 5 : 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeInOut(duration: 0.2)) { hovered = hovering } }
        .pointerCursor()
    }
}
