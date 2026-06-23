import SwiftUI

struct DisplaysView: View {
    @StateObject private var vm = DisplaysViewModel()

    var body: some View {
        // A ScrollView keeps the detail bounded to the window height. Without it, the tall
        // fixed-height content overflows a short window and clips the tops of *both*
        // NavigationSplitView columns (the sidebar nav items disappear).
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                DisplayCanvas(
                    displays: vm.displays,
                    selectedID: vm.selectedID,
                    onSelect: vm.select,
                    onMove: vm.moveDisplay
                )
                .frame(height: 240)
                .glassCard()

                if let selected = vm.selected {
                    DisplayDetailPanel(display: selected, vm: vm)
                }

                lockScreenNote

                if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Displays")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer()
            Text("\(vm.displays.count) display\(vm.displays.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button { vm.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(8)
                    .background(Circle().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var lockScreenNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.display")
                .foregroundStyle(.secondary)
            Text("The lock screen shows a single image (from your main display). macOS doesn't allow a separate lock-screen wallpaper per monitor.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Canvas

/// A scaled, draggable map of the displays. Reports a new global origin when a tile is dropped.
///
/// The `GeometryReader` is safe here because the parent pins it to a fixed `.frame(height:)`
/// inside a `ScrollView`, so it reads a definite size every layout pass instead of an
/// ambiguous flexible one.
private struct DisplayCanvas: View {
    let displays: [DisplayInfo]
    let selectedID: CGDirectDisplayID?
    let onSelect: (CGDirectDisplayID) -> Void
    let onMove: (CGDirectDisplayID, CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let layout = CanvasLayout(displays: displays, canvasSize: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    DisplayTile(
                        display: display,
                        isSelected: display.id == selectedID,
                        baseRect: layout.rect(for: display),
                        onSelect: { onSelect(display.id) },
                        onDrop: { canvasOrigin in onMove(display.id, layout.toGlobal(canvasOrigin)) }
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Maps display frames (global CG coords) into the canvas's point space and back.
private struct CanvasLayout {
    let scale: CGFloat
    let offset: CGSize

    init(displays: [DisplayInfo], canvasSize: CGSize, padding: CGFloat = 0.82) {
        let frames = displays.map(\.frame)
        let union = frames.dropFirst().reduce(frames.first ?? CGRect(x: 0, y: 0, width: 1, height: 1)) { $0.union($1) }
        let valid = union.width > 0 && union.height > 0 && canvasSize.width > 0 && canvasSize.height > 0
        let s = valid ? min(canvasSize.width / union.width, canvasSize.height / union.height) * padding : 1
        scale = s
        offset = CGSize(
            width: (canvasSize.width - union.width * s) / 2 - union.minX * s,
            height: (canvasSize.height - union.height * s) / 2 - union.minY * s
        )
    }

    func rect(for display: DisplayInfo) -> CGRect {
        CGRect(
            x: display.frame.minX * scale + offset.width,
            y: display.frame.minY * scale + offset.height,
            width: display.frame.width * scale,
            height: display.frame.height * scale
        )
    }

    func toGlobal(_ canvasOrigin: CGPoint) -> CGPoint {
        CGPoint(x: (canvasOrigin.x - offset.width) / scale, y: (canvasOrigin.y - offset.height) / scale)
    }
}

private struct DisplayTile: View {
    let display: DisplayInfo
    let isSelected: Bool
    let baseRect: CGRect
    let onSelect: () -> Void
    let onDrop: (CGPoint) -> Void

    @State private var drag: CGSize = .zero

    private let accent = Color(red: 0.55, green: 0.50, blue: 0.85)

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? accent.opacity(0.22) : Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? accent : Color.primary.opacity(0.15),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .overlay(tileLabel)
            .frame(width: baseRect.width, height: baseRect.height)
            .offset(x: baseRect.minX + drag.width, y: baseRect.minY + drag.height)
            .pointerCursor()
            .onTapGesture { onSelect() }
            .highPriorityGesture(
                DragGesture()
                    .onChanged { value in
                        if drag == .zero { onSelect() }
                        drag = value.translation
                    }
                    .onEnded { value in
                        onDrop(CGPoint(x: baseRect.minX + value.translation.width,
                                       y: baseRect.minY + value.translation.height))
                        drag = .zero
                    }
            )
            .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    private var tileLabel: some View {
        VStack(spacing: 2) {
            if display.isMain {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
            }
            Text(display.name)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Text(display.resolutionLabel)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(4)
        .frame(maxWidth: baseRect.width)
    }
}

// MARK: - Detail panel

private struct DisplayDetailPanel: View {
    let display: DisplayInfo
    @ObservedObject var vm: DisplaysViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            thumbnail

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(display.name)
                        .font(.headline)
                    if display.isMain {
                        Label("Main", systemImage: "star.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(display.resolutionLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button { vm.chooseWallpaper(for: display) } label: {
                    Label("Choose Image…", systemImage: "photo")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                ScalingPicker(selected: display.scaling) { vm.setScaling($0, for: display) }

                HStack(spacing: 12) {
                    ColorPicker("Background", selection: Binding(
                        get: { display.fillColor },
                        set: { vm.setFillColor($0, for: display) }
                    ))
                    .labelsHidden()
                    Text("Background color")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if !display.isMain {
                        Button { vm.makeMain(display.id) } label: {
                            Label("Set as Main", systemImage: "star")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Capsule().fill(.ultraThinMaterial))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .glassCard()
    }

    private var thumbnail: some View {
        Group {
            if let url = display.wallpaperURL {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ProgressView()
                }
            } else {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 160, height: 100)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.3), lineWidth: 1))
    }
}

private struct ScalingPicker: View {
    let selected: WallpaperScaling
    let onSelect: (WallpaperScaling) -> Void

    private let accent = Color(red: 0.55, green: 0.50, blue: 0.85)

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WallpaperScaling.allCases) { scaling in
                let isOn = scaling == selected
                Button { onSelect(scaling) } label: {
                    Label(scaling.displayName, systemImage: scaling.systemImage)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .foregroundStyle(isOn ? .white : .primary)
                        .background(Capsule().fill(isOn ? AnyShapeStyle(accent) : AnyShapeStyle(.ultraThinMaterial)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }
}
