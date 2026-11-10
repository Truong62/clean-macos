import SwiftUI

struct HomebrewView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case installed = "Installed"
        case search = "Search"

        var id: String { rawValue }
    }

    @EnvironmentObject var brew: HomebrewController
    @State private var mode = Mode.installed
    @State private var filter = BrewFilter.all
    @State private var query = ""
    @State private var groupsDependencies = true
    @State private var expanded: Set<String> = []
    @State private var pending: BrewAction?
    @State private var isConfirmingInstaller = false
    @State private var selectedHit: BrewSearchHit?
    @State private var details: (hit: BrewSearchHit, package: BrewPackage?)?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                PageHeader(icon: "mug.fill", title: "Homebrew", subtitle: "Search, install, upgrade and remove formulae and casks.",
                           colors: [.orange, .brown])
                if brew.client == nil {
                    missing
                } else {
                    controls
                    BrewJobCard(brew: brew)
                    if mode == .installed { installed } else { search }
                }
                if !brew.message.isEmpty {
                    Text(brew.message).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await brew.loadIfNeeded() }
        .alert(pending?.title ?? "", isPresented: isConfirming, presenting: pending) { action in
            Button("Cancel", role: .cancel) { }
            Button(action.confirmTitle, role: action.isDestructive ? .destructive : nil) { brew.run(action) }
        } message: { action in
            Text("Runs: \(action.commandLine(brew: brew.client?.path ?? "brew"))")
        }
        .alert("Install Homebrew?", isPresented: $isConfirmingInstaller) {
            Button("Cancel", role: .cancel) { }
            Button("Open Terminal") { brew.installHomebrew() }
        } message: {
            Text("Terminal opens and runs the official installer. It explains each step and asks for your password there.")
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var missing: some View {
        CardSection(title: "Homebrew is not installed", icon: "exclamationmark.triangle.fill") {
            Text("Homebrew installs command-line tools and apps. \(AppIdentity.installedName) can open Terminal with the official installer, so you see every step and type your password there yourself.")
                .font(.callout)
            Text(TerminalScript.homebrewInstaller)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button("Install Homebrew…") { isConfirmingInstaller = true }
                    .buttonStyle(.borderedProminent)
                Button("Check Again") { Task { await brew.loadIfNeeded() } }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
                Picker("Show", selection: $filter) {
                    ForEach(BrewFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 250)
                Spacer()
                if brew.isLoading || brew.isSearching { ProgressView().controlSize(.small) }
                Button { Task { await brew.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .disabled(brew.isLoading)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField(mode == .search ? "Search formulae and casks, then press Return" : "Filter installed packages", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { if mode == .search { Task { await brew.search(query) } } }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var installed: some View {
        CardSection(title: "Installed · \(brew.packages.count)", icon: "shippingbox.fill") {
            HStack {
                Toggle("Group dependencies", isOn: $groupsDependencies)
                    .toggleStyle(.switch)
                    .help("Show packages you did not ask for under the packages that need them")
                Spacer()
                Button("Update Homebrew") { pending = .update }
                    .disabled(brew.isBusy)
                    .help("Runs brew update")
                Button("Upgrade All (\(brew.upgradable.count))") { pending = .upgradeAll }
                    .buttonStyle(.borderedProminent)
                    .disabled(brew.isBusy || brew.upgradable.isEmpty)
                    .help("Runs brew upgrade")
            }
            if let tap = brew.untrustedTap {
                HStack {
                    Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                    Text("Homebrew skips \(tap) because you have not trusted it.").font(.callout)
                    Spacer()
                    Button("Trust \(tap)…") { pending = .trustTap(tap) }.disabled(brew.isBusy)
                }
            }
            if !brew.hasLoaded {
                Text("Loading…").foregroundStyle(.secondary)
            } else if groupsDependencies {
                grouped
            } else {
                rows(brew.packages.filter(isVisible))
            }
        }
    }

    @ViewBuilder private var grouped: some View {
        let groups = brew.tree.groups.filter { filter.includes($0.package.kind) && (matches($0.package) || $0.dependencies.contains(where: matches)) }
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                groupRow(group)
                Divider()
            }
        }
        let leftovers = brew.tree.leftovers.filter(isVisible)
        if !leftovers.isEmpty {
            Text("Leftover dependencies · nothing installed needs these anymore")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 8)
            rows(leftovers)
        }
    }

    private func rows(_ packages: [BrewPackage]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(packages) { package in
                row(package)
                Divider()
            }
        }
    }

    private func groupRow(_ group: BrewGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            row(group.package)
            if !group.dependencies.isEmpty {
                Button {
                    if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) }
                } label: {
                    Label("\(group.dependencies.count) \(group.dependencies.count == 1 ? "dependency" : "dependencies")",
                          systemImage: expanded.contains(group.id) ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(.leading, 28)
                .padding(.bottom, 6)
                if expanded.contains(group.id) {
                    ForEach(group.dependencies) { dependency in
                        row(dependency).padding(.leading, 28)
                    }
                }
            }
        }
    }

    private func row(_ package: BrewPackage) -> some View {
        let outdated = brew.outdatedEntry(for: package)
        return HStack(spacing: 10) {
            Image(systemName: package.kind == .cask ? "macwindow" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name).fontWeight(.medium)
                    Text(versionText(package, outdated: outdated))
                        .font(.caption)
                        .foregroundStyle(outdated == nil ? Color.secondary : Color.orange)
                    if package.isPinned || outdated?.isPinned == true {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).help("Pinned, so brew upgrade skips it")
                    }
                }
                if !package.summary.isEmpty {
                    Text(package.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let outdated, !outdated.isPinned {
                Button("Upgrade") { pending = .upgrade(package.kind, package.fullName) }.disabled(brew.isBusy)
            }
            Button("Uninstall") { pending = .uninstall(package.kind, package.fullName) }.disabled(brew.isBusy)
        }
        .padding(.vertical, 6)
    }

    private var search: some View {
        let hits = brew.results.filter { filter.includes($0.kind) }
        return CardSection(title: "Search", icon: "magnifyingglass") {
            if hits.isEmpty {
                Text(brew.isSearching ? "Searching…" : brew.searchedQuery.isEmpty ? "Type a name above and press Return." : "Nothing found for “\(brew.searchedQuery)”.")
                    .foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(hits) { hit in
                    hitRow(hit)
                    Divider()
                }
            }
        }
    }

    private func hitRow(_ hit: BrewSearchHit) -> some View {
        let installed = brew.installedPackage(for: hit)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: hit.kind == .cask ? "macwindow" : "terminal")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Button { select(hit) } label: { Text(hit.name).fontWeight(.medium) }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Show details")
                Text(hit.kind.title).font(.caption).foregroundStyle(.secondary)
                if let count = brew.popularity[hit.id] {
                    Text("\(count.formatted(.number.notation(.compactName))) installs in 30 days").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if let installed {
                    Text("Installed").font(.caption).foregroundStyle(.green)
                    Button("Uninstall") { pending = .uninstall(hit.kind, installed.fullName) }.disabled(brew.isBusy)
                } else {
                    Button("Install") { pending = .install(hit.kind, hit.name) }
                        .buttonStyle(.borderedProminent)
                        .disabled(brew.isBusy)
                }
            }
            if selectedHit == hit { detail(for: hit) }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private func detail(for hit: BrewSearchHit) -> some View {
        if let details, details.hit == hit {
            if let package = details.package {
                VStack(alignment: .leading, spacing: 4) {
                    if !package.summary.isEmpty { Text(package.summary).font(.callout) }
                    Text("Latest version \(AppVersion.caskVersion(package.latestVersion))").font(.caption).foregroundStyle(.secondary)
                    if let homepage = package.homepage { Link(homepage.absoluteString, destination: homepage).font(.caption) }
                }
                .padding(.leading, 28)
            } else {
                Text("Homebrew has no details for \(hit.name).").font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
            }
        } else {
            ProgressView().controlSize(.small).padding(.leading, 28)
        }
    }

    private func select(_ hit: BrewSearchHit) {
        guard selectedHit != hit else {
            selectedHit = nil
            return
        }
        selectedHit = hit
        details = nil
        Task {
            let package = await brew.details(for: hit)
            if selectedHit == hit { details = (hit, package) }
        }
    }

    private func isVisible(_ package: BrewPackage) -> Bool {
        filter.includes(package.kind) && matches(package)
    }

    private func matches(_ package: BrewPackage) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || package.name.localizedCaseInsensitiveContains(text) || package.summary.localizedCaseInsensitiveContains(text)
    }

    private func versionText(_ package: BrewPackage, outdated: BrewOutdated?) -> String {
        let installed = AppVersion.caskVersion(package.installedVersion ?? package.latestVersion)
        return outdated.map { "\(installed) → \(AppVersion.caskVersion($0.currentVersion))" } ?? installed
    }
}

struct BrewJobCard: View {
    private static let bottom = "bottom"

    @ObservedObject var brew: HomebrewController
    @State private var trusting: String?

    var body: some View {
        if let job = brew.job {
            CardSection(title: job.isRunning ? "Running" : "Finished", icon: "terminal.fill") {
                HStack(spacing: 10) {
                    Text(job.action.title).font(.headline)
                    Spacer()
                    if job.isRunning {
                        Button("Cancel") { brew.cancelJob() }.disabled(job.isCancelling)
                    } else {
                        Button("Close") { brew.dismissJob() }
                    }
                }
                Text(job.commandLine).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                if job.isRunning { progress(job) }
                output(job)
                if !job.isRunning { outcome(job) }
            }
            .alert("Trust \(trusting ?? "")?", isPresented: Binding(get: { trusting != nil }, set: { if !$0 { trusting = nil } })) {
                Button("Cancel", role: .cancel) { }
                Button("Trust") { if let tap = trusting { brew.run(.trustTap(tap)) } }
            } message: {
                Text("Runs: brew trust --tap \(trusting ?? ""). Homebrew then loads formulae and casks from this tap. Only trust taps you know.")
            }
        }
    }

    @ViewBuilder private func progress(_ job: BrewJob) -> some View {
        if let percent = job.log.percent {
            ProgressView(value: percent, total: 100)
        } else {
            ProgressView().progressViewStyle(.linear)
        }
        Text(job.log.phase.isEmpty ? job.statusText : job.log.phase)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func output(_ job: BrewJob) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(job.log.text.isEmpty ? " " : job.log.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id(Self.bottom)
            }
            .frame(height: 180)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: job.log.lines.count) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
        }
    }

    @ViewBuilder private func outcome(_ job: BrewJob) -> some View {
        Label(job.statusText, systemImage: job.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .foregroundStyle(job.succeeded ? Color.green : job.isCancelling ? Color.secondary : Color.red)
        if let tap = job.untrustedTap {
            HStack {
                Text("Homebrew does not trust \(tap) yet.").font(.callout)
                Button("Trust \(tap)…") { trusting = tap }
            }
        }
        if job.needsTerminal {
            Text("This step needs your password, which \(AppIdentity.installedName) never types for you. Run the command yourself in Terminal:")
                .font(.callout)
            HStack {
                Text(job.commandLine).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Copy Command") { ScreenTools.copy(job.commandLine) }
            }
        }
    }
}
