import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                // App icon — soft pastel accent
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(appPastelGradient)
                        .frame(width: 96, height: 96)
                        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)

                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                }

                // App info
                VStack(spacing: 6) {
                    Text("Clean macOS")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Version \(appVersion)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Description
                VStack(spacing: 8) {
                    Text("Scan your Mac for junk files, caches, build artifacts, and forgotten data. Reclaim gigabytes of disk space.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text("This is a personal learning project. Completely free, no charges.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 420)

                Divider()
                    .frame(width: 200)
                    .padding(.vertical, 8)

                // Tech stack
                HStack(spacing: 24) {
                    TechBadge(label: "Swift 6", icon: "swift", color: .orange)
                    TechBadge(label: "SwiftUI", icon: "macwindow", color: .blue)
                    TechBadge(label: "Native", icon: "cpu", color: .green)
                }

                Divider()
                    .frame(width: 200)
                    .padding(.vertical, 8)

                // Links
                VStack(spacing: 10) {
                    LinkRow(title: "Website", subtitle: "ngoctruong.click", icon: "globe", color: .blue, url: "https://ngoctruong.click")
                    LinkRow(title: "Source Code", subtitle: "github.com/Truong62/clean-macos", icon: "chevron.left.forwardslash.chevron.right", color: .purple, url: "https://github.com/Truong62/clean-macos")
                    LinkRow(title: "Report Issue", subtitle: "Open a GitHub issue", icon: "ladybug", color: .red, url: "https://github.com/Truong62/clean-macos/issues")
                    LinkRow(title: "License", subtitle: "MIT License", icon: "doc.text", color: .gray, url: nil)
                }
                .frame(width: 320)

                Divider()
                    .frame(width: 200)
                    .padding(.vertical, 8)

                Text("Made with ♥ by Ngoc Truong")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 40)
            .padding(.horizontal, 44)
            .glassCard(cornerRadius: 28)
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    // Light base with a soft pastel glow pooling at the bottom (matching Home).
    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack {
                Spacer()
                appPastelGradient
                    .frame(height: 320)
                    .blur(radius: 90)
                    .opacity(0.35)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Tech Badge

struct TechBadge: View {
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color.gradient)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(width: 80)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 14)
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
