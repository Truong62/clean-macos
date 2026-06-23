import SwiftUI
import AppKit

@MainActor
final class DisplaysViewModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var selectedID: CGDirectDisplayID?
    @Published var statusMessage = ""

    private let service: DisplayService

    init(service: DisplayService = DisplayService()) {
        self.service = service
        refresh()
        startObservingScreenChanges()
    }

    // MARK: - Derived

    var selected: DisplayInfo? {
        displays.first { $0.id == selectedID }
    }

    // MARK: - Loading

    func refresh() {
        displays = service.currentDisplays()
        if selectedID == nil || !displays.contains(where: { $0.id == selectedID }) {
            selectedID = displays.first(where: \.isMain)?.id ?? displays.first?.id
        }
    }

    func select(_ id: CGDirectDisplayID) {
        selectedID = id
    }

    // MARK: - Wallpaper

    /// Open a picker and set the chosen image as `display`'s wallpaper.
    func chooseWallpaper(for display: DisplayInfo) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Set Wallpaper"
        panel.message = "Choose a wallpaper for \(display.name)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        apply(to: display.id, status: "Wallpaper updated for \(display.name)") { id in
            try self.service.setWallpaper(url: url,
                                          scaling: display.scaling,
                                          fillColor: NSColor(display.fillColor),
                                          displayID: id)
        }
    }

    func setScaling(_ scaling: WallpaperScaling, for display: DisplayInfo) {
        apply(to: display.id, status: "\(display.name): \(scaling.displayName)") { id in
            try self.service.setAppearance(scaling: scaling,
                                           fillColor: NSColor(display.fillColor),
                                           displayID: id)
        }
    }

    func setFillColor(_ color: Color, for display: DisplayInfo) {
        apply(to: display.id, status: "\(display.name): background color updated") { id in
            try self.service.setAppearance(scaling: display.scaling,
                                           fillColor: NSColor(color),
                                           displayID: id)
        }
    }

    // MARK: - Arrangement

    /// Drag-drop a display to a proposed global origin: snap it flush, reject overlaps, then commit.
    func moveDisplay(_ id: CGDirectDisplayID, toGlobalOrigin proposed: CGPoint) {
        guard let moving = displays.first(where: { $0.id == id }) else { return }
        let others = displays.filter { $0.id != id }.map(\.frame)

        let snapped = DisplayArrangement.snap(size: moving.frame.size, proposedOrigin: proposed, others: others)
        let snappedRect = CGRect(origin: snapped, size: moving.frame.size)

        guard !DisplayArrangement.overlaps(snappedRect, others) else {
            statusMessage = "Can't drop there — displays would overlap."
            refresh()
            return
        }

        apply(to: id, status: "Rearranged \(moving.name)") { _ in
            try self.service.applyArrangement(origins: [id: snapped])
        }
    }

    func makeMain(_ id: CGDirectDisplayID) {
        let origins = DisplayArrangement.origins(makingMain: id, from: displays)
        guard !origins.isEmpty else { return }
        let name = displays.first { $0.id == id }?.name ?? "display"
        apply(to: id, status: "\(name) is now the main display") { _ in
            try self.service.applyArrangement(origins: origins)
        }
    }

    // MARK: - Private

    /// Run a system mutation, keep `id` selected, refresh, and report success/failure uniformly.
    private func apply(to id: CGDirectDisplayID, status: String, _ work: (CGDirectDisplayID) throws -> Void) {
        do {
            try work(id)
            selectedID = id
            refresh()
            statusMessage = status
        } catch {
            statusMessage = error.localizedDescription
            refresh()
        }
    }

    private func startObservingScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
