import SwiftUI

struct CleanDiskView: View {
    @EnvironmentObject var vm: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            DashboardView()

            ToolbarRow()

            Divider().opacity(0.5)

            ArtifactTableView()

            if !vm.snapshots.isEmpty {
                SnapshotSection()
            }

            StatusBar()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
