import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var updater: UpdaterViewModel
    @EnvironmentObject var clipboard: ClipboardViewModel
    @AppStorage(ClipboardSettings.persistKey) private var clipboardPersist = true
    @AppStorage(ClipboardSettings.maxItemsKey) private var clipboardMaxItems = ClipboardSettings.defaultMaxItems
    @AppStorage(ClipboardSettings.skipConcealedKey) private var clipboardSkipConcealed = false
    @State private var accessibilityTrusted = PasteService.isAccessibilityTrusted

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                headerCard

                // Scan settings
                section(icon: "magnifyingglass", iconColor: .blue, title: "Scan") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Default scan path")
                                .fontWeight(.medium)
                            Text("Root directory to start scanning from")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        TextField("Path", text: $vm.scanPath)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 300)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Minimum file size")
                                .fontWeight(.medium)
                            Text("Ignore items smaller than this")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $vm.minFileSizeMB) {
                            Text("1 MB").tag(1)
                            Text("10 MB").tag(10)
                            Text("50 MB").tag(50)
                            Text("100 MB").tag(100)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                    }

                    Toggle(isOn: $vm.skipHidden) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip hidden directories")
                                .fontWeight(.medium)
                            Text("Don't scan directories starting with a dot")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Safety settings
                section(icon: "shield.checkered", iconColor: .green, title: "Safety") {
                    Toggle(isOn: $vm.confirmBeforeClean) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Confirm before cleaning")
                                .fontWeight(.medium)
                            Text("Show confirmation dialog before deleting files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Menu Bar settings
                section(icon: "menubar.rectangle", iconColor: .cyan, title: "Menu Bar") {
                    Toggle(isOn: $vm.showMenuBar) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show in menu bar")
                                .fontWeight(.medium)
                            Text("Display CPU, RAM, and disk usage in the top bar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Clipboard settings
                section(icon: "doc.on.clipboard", iconColor: .indigo, title: "Clipboard") {
                    Toggle(isOn: $clipboardPersist) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep history after quitting")
                                .fontWeight(.medium)
                            Text("Save clipboard history to disk so it survives a restart")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: clipboardPersist) { _, _ in
                        clipboard.persistenceSettingChanged()
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Maximum items")
                                .fontWeight(.medium)
                            Text("Oldest items are dropped beyond this count")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $clipboardMaxItems) {
                            Text("50").tag(50)
                            Text("100").tag(100)
                            Text("200").tag(200)
                            Text("500").tag(500)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("History shortcut")
                                .fontWeight(.medium)
                            Text("Global hotkey to open the clipboard picker")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .showClipboardHistory)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-paste")
                                .fontWeight(.medium)
                            Text(accessibilityTrusted
                                 ? "Accessibility granted — picks paste automatically"
                                 : "Grant Accessibility to paste the picked item automatically")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if accessibilityTrusted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                        } else {
                            Button("Open Accessibility…") {
                                PasteService.requestAccessibility()
                                PasteService.openAccessibilitySettings()
                            }
                            .pointerCursor()
                        }
                    }

                    Toggle(isOn: $clipboardSkipConcealed) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Skip passwords")
                                .fontWeight(.medium)
                            Text("Don't capture clipboard marked private by password managers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Update settings
                section(icon: "arrow.triangle.2.circlepath", iconColor: .purple, title: "Updates") {
                    Toggle(isOn: updater.automaticallyChecksForUpdates) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check for updates automatically")
                                .fontWeight(.medium)
                            Text("Notify when a new version is available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Label("Check for Updates Now", systemImage: "arrow.clockwise")
                    }
                    .disabled(!updater.canCheckForUpdates)
                    .pointerCursor()
                }

                Spacer()
            }
            .padding(20)
        }
        .background(background)
        .onAppear { accessibilityTrusted = PasteService.isAccessibilityTrusted }
    }

    // MARK: - Header

    private var headerCard: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(appPastelGradient)
                .frame(width: 46, height: 46)
                .overlay(Image(systemName: "gearshape.fill").font(.system(size: 18)).foregroundStyle(.white))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("Settings")
                    .font(.title2).fontWeight(.bold)
                Text("Configure how Clean macOS works")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .glassCard(cornerRadius: 22)
    }

    // MARK: - Section container (frosted card with soft uppercase header)

    @ViewBuilder
    private func section<Content: View>(
        icon: String,
        iconColor: Color,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor.gradient)
                    .font(.subheadline)
                Text(title.uppercased())
                    .font(.caption2).fontWeight(.semibold)
                    .foregroundStyle(.tertiary).tracking(1)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
    }

    // MARK: - Background (light base with soft pastel glow, matching Home)

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
