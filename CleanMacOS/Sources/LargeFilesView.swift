import SwiftUI

enum AgeFilter: String, CaseIterable, Identifiable {
    case any, month, sixMonths, year
    var id: String { rawValue }
    var label: String {
        switch self {
        case .any: "Any age"
        case .month: "Older than 1 month"
        case .sixMonths: "Older than 6 months"
        case .year: "Older than 1 year"
        }
    }
    /// Files must be modified at or before this date to match. nil = no age filter.
    var cutoff: Date? {
        let cal = Calendar.current
        switch self {
        case .any: return nil
        case .month: return cal.date(byAdding: .month, value: -1, to: Date())
        case .sixMonths: return cal.date(byAdding: .month, value: -6, to: Date())
        case .year: return cal.date(byAdding: .year, value: -1, to: Date())
        }
    }
}

@MainActor
final class LargeFilesViewModel: ObservableObject {
    @Published var root: String
    @Published var files: [LargeFile] = []
    @Published var selected: Set<LargeFile.ID> = []
    @Published var isScanning = false
    @Published var isDeleting = false
    @Published var status = "Ready"
    @Published var minSizeMB = 50
    @Published var ageFilter: AgeFilter = .any
    @Published var includeLibrary = false
    @Published var showConfirm = false

    private let service = LargeFilesService()
    private let cleaner = CleanerService()

    init() {
        root = FileManager.default.homeDirectoryForCurrentUser.path
    }

    var selectedSize: Int64 {
        files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    var canDelete: Bool { !selected.isEmpty && !isDeleting && !isScanning }

    func scan() async {
        isScanning = true
        selected = []
        status = "Scanning \(root)..."
        let minBytes = Int64(minSizeMB) * 1_048_576
        let cutoff = ageFilter.cutoff
        let root = self.root
        let excludeLibrary = !includeLibrary
        let found = await Task.detached { [service] in
            service.scan(root: root, minBytes: minBytes, olderThan: cutoff, excludeLibrary: excludeLibrary)
        }.value
        files = found
        isScanning = false
        let total = found.reduce(Int64(0)) { $0 + $1.size }
        status = "\(found.count) files — \(formatBytes(total))"
    }

    func delete() async {
        let paths = files.filter { selected.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        isDeleting = true
        status = "Moving \(paths.count) files to Trash..."
        let result = await Task.detached { [cleaner] in cleaner.moveToTrash(paths) }.value
        let trashed = Set(result.deleted.filter(\.success).map(\.path))
        files.removeAll { trashed.contains($0.path) }
        selected = []
        isDeleting = false
        status = result.failCount > 0
            ? "Moved \(result.okCount) (\(result.freedStr)), \(result.failCount) failed"
            : "Moved \(result.okCount) files to Trash — \(result.freedStr)"
    }

    func toggle(_ file: LargeFile) {
        if selected.contains(file.id) { selected.remove(file.id) } else { selected.insert(file.id) }
    }
}

struct LargeFilesView: View {
    @StateObject private var vm = LargeFilesViewModel()
    @State private var sortOrder = [KeyPathComparator(\LargeFile.size, order: .reverse)]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Move to Trash?", isPresented: $vm.showConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) { Task { await vm.delete() } }
        } message: {
            Text("Move \(vm.selected.count) file(s) — \(formatBytes(vm.selectedSize)) — to the Trash. You can restore them if needed.")
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(.blue).font(.caption)
                    TextField("Folder to scan", text: $vm.root)
                        .textFieldStyle(.plain).font(.callout)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Button {
                    Task { await vm.scan() }
                } label: {
                    HStack(spacing: 5) {
                        if vm.isScanning { ProgressView().controlSize(.small) }
                        else { Image(systemName: "magnifyingglass") }
                        Text("Scan")
                    }.padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isScanning)
            }

            HStack(spacing: 12) {
                Picker("Min size", selection: $vm.minSizeMB) {
                    Text("≥ 10 MB").tag(10)
                    Text("≥ 50 MB").tag(50)
                    Text("≥ 100 MB").tag(100)
                    Text("≥ 500 MB").tag(500)
                    Text("≥ 1 GB").tag(1024)
                }
                .frame(maxWidth: 160)

                Picker("Age", selection: $vm.ageFilter) {
                    ForEach(AgeFilter.allCases) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 200)

                Toggle("Include ~/Library", isOn: $vm.includeLibrary)
                    .toggleStyle(.checkbox)
                    .help("By default ~/Library is skipped (large, already handled by Home). Slower if enabled.")

                Spacer()

                Button {
                    vm.showConfirm = true
                } label: {
                    HStack(spacing: 5) {
                        if vm.isDeleting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "trash.fill") }
                        Text("Trash \(formatBytes(vm.selectedSize))").fontWeight(.medium)
                    }.padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .disabled(!vm.canDelete)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isScanning {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("Scanning for large files...").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.files.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.on.doc").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("No large files yet").font(.title3).fontWeight(.semibold)
                Text("Pick a folder and size, then Scan.").font(.callout).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(vm.files.sorted(using: sortOrder), selection: $vm.selected, sortOrder: $sortOrder) {
                TableColumn("") { file in
                    Toggle(isOn: Binding(get: { vm.selected.contains(file.id) }, set: { _ in vm.toggle(file) })) { }
                        .toggleStyle(.checkbox)
                }.width(30)

                TableColumn("Name", value: \.name) { file in
                    Text(file.name).fontWeight(.medium).lineLimit(1)
                }.width(min: 160, ideal: 220)

                TableColumn("Path") { file in
                    Text(file.path).font(.caption).fontDesign(.monospaced)
                        .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(file.path)
                }.width(min: 150, ideal: 260)

                TableColumn("Modified", value: \.modified) { file in
                    Text(Self.dateFormatter.string(from: file.modified))
                        .font(.caption).foregroundStyle(.secondary)
                }.width(min: 90, ideal: 110)

                TableColumn("Size", value: \.size) { file in
                    Text(file.sizeHuman).fontDesign(.rounded).fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }.width(min: 70, ideal: 90)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(vm.isScanning || vm.isDeleting ? .orange : .green).frame(width: 6, height: 6)
            Text(vm.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !vm.selected.isEmpty {
                Text("\(vm.selected.count) selected — \(formatBytes(vm.selectedSize))")
                    .font(.caption).fontWeight(.medium).foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6).background(.bar)
    }
}
