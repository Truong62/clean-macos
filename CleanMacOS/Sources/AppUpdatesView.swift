import SwiftUI

struct AppUpdatesView: View {
    @EnvironmentObject var updates: AppUpdatesController
    @EnvironmentObject var brew: HomebrewController
    @State private var isConfirming = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "arrow.down.app.fill", title: "App Updates",
                           subtitle: "Newer versions of your apps from Homebrew, the App Store and their publishers.", colors: [.blue, .cyan])
                status
                BrewJobCard(brew: brew)
                results
                if !updates.failures.isEmpty { failures }
                options
                if hasRules { rules }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { updates.checkIfStale() }
        .alert(confirmTitle, isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) { }
            Button("Update") { updates.update(updates.selectedUpdates) }
        } message: {
            Text(AppUpdatePlan(updates.selectedUpdates).summary)
        }
    }

    private var confirmTitle: String {
        let count = updates.selectedUpdates.count
        return count == 1 ? "Update 1 app?" : "Update \(count) apps?"
    }

    private var status: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                Text(statusDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if updates.isChecking { ProgressView().controlSize(.small) }
            Button { updates.check() } label: { Label("Check Now", systemImage: "arrow.clockwise") }
                .disabled(updates.isChecking)
        }
        .padding(18)
        .glassCard(cornerRadius: 20)
    }

    private var statusTitle: String {
        if updates.isChecking { return "Checking your apps…" }
        guard updates.report != nil else { return "Not checked yet" }
        let count = updates.updates.count
        return count == 0 ? "Everything is up to date" : count == 1 ? "1 update available" : "\(count) updates available"
    }

    private var statusDetail: String {
        var parts: [String] = []
        if let date = updates.settings.lastCheck { parts.append("Last checked \(date.formatted(.relative(presentation: .named)))") }
        if let report = updates.report { parts.append("\(report.checked) apps checked") }
        if !updates.message.isEmpty { parts.append(updates.message) }
        return parts.isEmpty ? "Checks the apps in Applications and the ones Spotlight finds in your home folder." : parts.joined(separator: " · ")
    }

    @ViewBuilder private var results: some View {
        let list = updates.updates
        if !list.isEmpty {
            CardSection(title: "Updates", icon: "arrow.down.circle.fill") {
                ForEach(list) { update in
                    row(update)
                    Divider()
                }
                HStack {
                    Button(isAllSelected ? "Select None" : "Select All") {
                        updates.selection = isAllSelected ? [] : Set(list.map(\.id))
                    }
                    Spacer()
                    Button("Update Selected (\(updates.selectedUpdates.count))") { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(updates.selectedUpdates.isEmpty)
                }
            }
        }
    }

    private var isAllSelected: Bool {
        updates.selectedUpdates.count == updates.updates.count
    }

    private func row(_ update: AppUpdate) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: selection(update.id))
                .labelsHidden()
                .toggleStyle(.checkbox)
            Image(nsImage: AppIconCache.image(for: update.app.bundleID) ?? NSWorkspace.shared.icon(forFile: update.app.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(update.app.name).fontWeight(.medium)
                Text("\(update.installed) → \(update.latest)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(update.source.title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.12), in: Capsule())
                .foregroundStyle(.blue)
            Menu {
                Button("Skip This Version") { updates.skip(update) }
                Button("Exclude This App") { updates.exclude(update.app.bundleID) }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: update.app.path)]) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private func selection(_ id: AppUpdate.ID) -> Binding<Bool> {
        Binding(get: { updates.selection.contains(id) }, set: { isOn in
            if isOn { updates.selection.insert(id) } else { updates.selection.remove(id) }
        })
    }

    private var failures: some View {
        CardSection(title: "Could not check", icon: "exclamationmark.triangle.fill") {
            ForEach(updates.failures) { failure in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.name).fontWeight(.medium)
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if let bundleID = failure.bundleID {
                        Button("Exclude") { updates.exclude(bundleID) }.help("Stop checking this app")
                    }
                }
            }
        }
    }

    private var options: some View {
        CardSection(title: "Options", icon: "slider.horizontal.3") {
            Picker("Check automatically", selection: $updates.settings.schedule) {
                ForEach(AppUpdateSchedule.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 320)
            Toggle(isOn: $updates.settings.notifies) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notify me when updates are found")
                    Text("After an automatic check while \(AppIdentity.installedName) runs in the background, once per update.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(updates.settings.schedule == .off && !updates.settings.notifies)
            Divider()
            source("Homebrew apps", detail: brew.client == nil ? "Homebrew is not installed." : "Matches casks to your apps. Updates run brew upgrade --cask --greedy.",
                   isOn: $updates.settings.checksHomebrew)
            source("App Store apps", detail: "Looks up apps from the Mac App Store. An update opens the store page.", isOn: $updates.settings.checksAppStore)
            source("Online catalog", detail: "Compares other apps with the Homebrew cask list on formulae.brew.sh. An update opens the app's homepage.",
                   isOn: $updates.settings.usesCatalog)
            Text("Apps with their own Sparkle or Electron update feed are always checked with their publisher over HTTPS.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func source(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var hasRules: Bool {
        !updates.settings.rules.excludedBundleIDs.isEmpty || !updates.settings.rules.skippedVersions.isEmpty
    }

    private var rules: some View {
        CardSection(title: "Rules", icon: "list.bullet.rectangle") {
            ForEach(updates.settings.rules.excludedBundleIDs, id: \.self) { bundleID in
                HStack {
                    Text("Never check \(appName(bundleID))")
                    Spacer()
                    Button("Remove") { updates.include(bundleID) }
                }
            }
            ForEach(updates.settings.rules.skippedVersions.sorted { $0.key < $1.key }, id: \.key) { bundleID, version in
                HStack {
                    Text("Skip \(appName(bundleID)) \(version)")
                    Spacer()
                    Button("Remove") { updates.unskip(bundleID) }
                }
            }
        }
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { $0.deletingPathExtension().lastPathComponent } ?? bundleID
    }
}
