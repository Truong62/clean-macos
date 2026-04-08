import SwiftUI

struct PermissionView: View {
    @EnvironmentObject var vm: AppViewModel
    @State private var checking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(.orange.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "lock.shield")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange.gradient)
            }

            // Title
            VStack(spacing: 8) {
                Text("Full Disk Access Required")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Clean macOS needs Full Disk Access to scan and clean system files, caches, and build artifacts. This is a one-time setup.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            // Steps
            VStack(alignment: .leading, spacing: 12) {
                StepRow(number: 1, text: "Click \"Open Settings\" below")
                StepRow(number: 2, text: "Find **Clean macOS** in the list")
                StepRow(number: 3, text: "Toggle it **ON**")
                StepRow(number: 4, text: "Come back and click \"I've Enabled It\"")
            }
            .padding(20)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Buttons
            HStack(spacing: 12) {
                Button {
                    // Open System Settings > Privacy > Full Disk Access
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Settings", systemImage: "gear")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    checking = true
                    // Re-check permission
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        vm.checkPermission()
                        checking = false
                    }
                } label: {
                    if checking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("I've Enabled It", systemImage: "checkmark.circle")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            // Skip
            Button {
                vm.skipPermissionCheck = true
            } label: {
                Text("Skip for now (limited scan)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Step Row

struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.blue)
                .clipShape(Circle())

            Text(text)
                .font(.callout)
        }
    }
}
