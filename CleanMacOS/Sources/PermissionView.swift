import SwiftUI

struct PermissionView: View {
    @EnvironmentObject var vm: AppViewModel

    private static let fullDiskAccessURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    private static let repoURL = "https://github.com/Truong62/clean-macos"
    private static let recheckInterval: Duration = .seconds(2)

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if vm.permissionLostAfterUpdate { updateNotice }
                steps
                actions
                freeAppNote
            }
            .padding(32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            while !Task.isCancelled && vm.needsPermission {
                try? await Task.sleep(for: Self.recheckInterval)
                vm.checkPermission()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(.orange.opacity(0.12)).frame(width: 84, height: 84)
                Image(systemName: vm.permissionLostAfterUpdate ? "arrow.triangle.2.circlepath" : "lock.shield")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.orange.gradient)
            }
            Text(vm.permissionLostAfterUpdate ? "Grant Access Again" : "Full Disk Access Required")
                .font(.title2)
                .fontWeight(.bold)
            Text("Clean macOS needs Full Disk Access to scan and clean caches, logs and build artifacts. Nothing leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var updateNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.appVersion.isEmpty ? "Just updated" : "Updated to \(vm.appVersion)")
                    .fontWeight(.semibold)
                Text("macOS sees each update as a new app, so the old permission no longer applies. Clean macOS may still look **ON** in the list — turn it **OFF and ON again**.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.blue.opacity(0.3), lineWidth: 1))
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepRow(number: 1, text: "Click **Open Settings** below")
            StepRow(number: 2, text: "Find **Clean macOS** and turn it **ON**")
            StepRow(number: 3, text: "Already ON? Turn it **OFF then ON**, or remove it with **−** and add it again with **+**")
            StepRow(number: 4, text: "Come back here — access is detected automatically")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    if let url = URL(string: Self.fullDiskAccessURL) { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open Settings", systemImage: "gear").padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .pointerCursor()

                Button(action: relaunch) {
                    Label("Quit & Reopen", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .pointerCursor()
                .help("Use this if access is still not detected after turning it on")
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Waiting for access…").font(.caption).foregroundStyle(.secondary)
            }
            Button("Skip for now (limited scan)") { vm.skipPermissionCheck = true }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .pointerCursor()
        }
    }

    private var freeAppNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "heart.fill")
                .foregroundStyle(.pink)
            VStack(alignment: .leading, spacing: 4) {
                Text("Why again after every update?")
                    .font(.callout)
                    .fontWeight(.semibold)
                Text("Clean macOS is free and open source, so it isn't signed with a paid Apple Developer certificate. Without that signature macOS can't tell a new version is the same app, so Full Disk Access and Accessibility need to be approved again after each update.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("View source on GitHub", destination: URL(string: Self.repoURL)!)
                    .font(.caption)
                    .pointerCursor()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }
}

struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.blue, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
