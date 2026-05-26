import SwiftUI
import AppKit

enum SidebarPage: Hashable {
    case home
    case cleanDisk
    case largeFiles
    case uninstall
    case clipboard
    case settings
    case about
}

struct SidebarView: View {
    @EnvironmentObject var vm: AppViewModel
    @Binding var currentPage: SidebarPage

    var body: some View {
        VStack(spacing: 0) {
            // Navigation
            VStack(spacing: 4) {
                SidebarItem(icon: "house.fill", label: "Home", color: .blue, isSelected: currentPage == .home) {
                    currentPage = .home
                }
                SidebarItem(icon: "internaldrive.fill", label: "Clean Disk", color: .teal, isSelected: currentPage == .cleanDisk) {
                    currentPage = .cleanDisk
                }
                SidebarItem(icon: "doc.text.magnifyingglass", label: "Large Files", color: .orange, isSelected: currentPage == .largeFiles) {
                    currentPage = .largeFiles
                }
                SidebarItem(icon: "trash.fill", label: "Uninstall Apps", color: .red, isSelected: currentPage == .uninstall) {
                    currentPage = .uninstall
                }
                SidebarItem(icon: "doc.on.clipboard.fill", label: "Clipboard", color: .indigo, isSelected: currentPage == .clipboard) {
                    currentPage = .clipboard
                }
                SidebarItem(icon: "gearshape.fill", label: "Settings", color: .gray, isSelected: currentPage == .settings) {
                    currentPage = .settings
                }
                SidebarItem(icon: "info.circle.fill", label: "About", color: .gray, isSelected: currentPage == .about) {
                    currentPage = .about
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if currentPage == .cleanDisk && !vm.categoryCounts.isEmpty {
                Divider()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)

                // Categories header
                HStack {
                    Text("CATEGORIES")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.8)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

                ScrollView {
                    VStack(spacing: 2) {
                        CategoryRow(
                            icon: "square.grid.2x2",
                            label: "All",
                            count: vm.artifacts.count,
                            size: formatBytes(vm.totalCleanableSize),
                            color: .blue,
                            isSelected: vm.selectedCategory == nil
                        ) {
                            vm.selectedCategory = nil
                        }

                        ForEach(vm.categoryCounts, id: \.0) { cat, count, size in
                            CategoryRow(
                                icon: cat.icon,
                                label: cat.displayName,
                                count: count,
                                size: formatBytes(size),
                                color: cat.color,
                                isSelected: vm.selectedCategory == cat
                            ) {
                                vm.selectedCategory = cat
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            Spacer()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }
}

// MARK: - Liquid glass pill (shared selected/hover background)

private struct LiquidPill: View {
    let isSelected: Bool
    let isHovered: Bool
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
            .overlay {
                if isSelected {
                    // glossy top sheen
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom))
                        .blendMode(.plusLighter)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.4), lineWidth: 1)
                }
            }
            .shadow(color: isSelected ? color.opacity(0.5) : .clear, radius: 8, y: 3)
    }

    private var fill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(color.gradient) }
        if isHovered { return AnyShapeStyle(.ultraThinMaterial) }
        return AnyShapeStyle(Color.clear)
    }
}

// MARK: - Sidebar Item (Home, Settings, About)

struct SidebarItem: View {
    let icon: String
    let label: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? .white : color)
                    .frame(width: 20)

                Text(label)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(LiquidPill(isSelected: isSelected, isHovered: isHovered, color: color))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Category Row

struct CategoryRow: View {
    let icon: String
    let label: String
    let count: Int
    let size: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : color)
                    .frame(width: 20)

                Text(label)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    Text(size)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.gray)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(LiquidPill(isSelected: isSelected, isHovered: isHovered, color: color))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
