import SwiftUI
import AppKit

struct CleanResultsView: View {
    @EnvironmentObject var vm: AppViewModel

    private var result: CleanResult? { vm.lastCleanResult }

    private var sortedResults: [DeleteResult] {
        result?.deleted.sorted { lhs, rhs in
            if lhs.success != rhs.success { return !lhs.success }
            return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
        } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(sortedResults) { item in
                        resultRow(item)
                    }
                }
                .padding(16)
            }
            Divider()
            actions
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 520, idealHeight: 640)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clean Results")
                .font(.title2)
                .fontWeight(.bold)

            HStack(spacing: 12) {
                metric("Items cleaned", value: "\(result?.okCount ?? 0)", color: .green)
                metric("Real space freed", value: result?.realFreedStr ?? "0 B", color: .blue)
                metric("Estimated freed", value: result?.freedStr ?? "0 B", color: .purple)
                metric("Failures", value: "\(result?.detailedFailureCount ?? 0)", color: .red)
            }

            Text("Real and estimated totals can differ because APFS snapshots and purgeable space are accounted for separately.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func metric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func resultRow(_ item: DeleteResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(item.success ? .green : .red)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.name)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(formatBytes(item.size))
                            .fontDesign(.rounded)
                            .foregroundStyle(.secondary)
                    }
                    Text(item.path)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                    if let error = item.error, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if item.freedBytes > 0 {
                        Text("Estimated freed: \(formatBytes(item.freedBytes))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(item.failures) { failure in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .foregroundStyle(.secondary)
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(failure.name)
                                .fontWeight(.medium)
                            Spacer()
                            Text(formatBytes(failure.size))
                                .foregroundStyle(.secondary)
                        }
                        Text(failure.path)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .textSelection(.enabled)
                        Text(failure.error ?? "Delete failed")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(12)
        .background(item.success ? Color.green.opacity(0.05) : Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if result?.retryArtifacts.isEmpty == false {
                Button("Retry failed as administrator") {
                    Task { await vm.retryFailedAsAdministrator() }
                }
                .disabled(vm.isCleaning)
            }
            Spacer()
            Button("Copy report") {
                guard let report = result?.plainTextReport else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
            Button("Done") {
                vm.showResults = false
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }
}
