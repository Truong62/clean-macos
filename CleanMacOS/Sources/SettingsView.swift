import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var updater: UpdaterViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Settings")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        Text("Configure how Clean macOS works")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                // Scan settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.blue.gradient)
                                .font(.title3)
                            Text("Scan")
                                .font(.headline)
                        }

                        Divider()

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
                    .padding(4)
                }

                // Safety settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "shield.checkered")
                                .foregroundStyle(.green.gradient)
                                .font(.title3)
                            Text("Safety")
                                .font(.headline)
                        }

                        Divider()

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
                    .padding(4)
                }

                // Menu Bar settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "menubar.rectangle")
                                .foregroundStyle(.cyan.gradient)
                                .font(.title3)
                            Text("Menu Bar")
                                .font(.headline)
                        }

                        Divider()

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
                    .padding(4)
                }

                // Update settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.purple.gradient)
                                .font(.title3)
                            Text("Updates")
                                .font(.headline)
                        }

                        Divider()

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
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
