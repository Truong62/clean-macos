import SwiftUI
import AppKit

enum SidebarPage: Hashable {
    case home
    case cleanDisk
    case largeFiles
    case uninstall
    case clipboard
    case displays
    case screenRecord
    case typing
    case music
    case ram
    case portsJobs
    case powerRecovery
    case devTools
    case settings
    case about
}

struct SidebarView: View {
    @EnvironmentObject var vm: AppViewModel
    @Binding var currentPage: SidebarPage

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    SidebarItem(icon: "house.fill", label: "Home", color: .blue, isSelected: currentPage == .home) {
                        currentPage = .home
                    }
                    ForEach(ToolGroup.allCases) { group in
                        SidebarGroupHeader(title: group.title)
                        ForEach(group.tools) { tool in
                            SidebarItem(icon: tool.icon, label: tool.title, color: tool.color, isSelected: currentPage == tool.page) {
                                currentPage = tool.page
                            }
                            if currentPage == tool.page {
                                subSection(for: tool.page)
                            }
                        }
                    }
                    Divider()
                        .padding(.vertical, 6)
                    SidebarItem(icon: "gearshape.fill", label: "Settings", color: .gray, isSelected: currentPage == .settings) {
                        currentPage = .settings
                    }
                    if currentPage == .settings {
                        SettingsSidebarSection()
                            .transition(.sidebarDisclosure)
                    }
                    SidebarItem(icon: "info.circle.fill", label: "About", color: .gray, isSelected: currentPage == .about) {
                        currentPage = .about
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }

            ReleaseHistoryButton()
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.25), value: currentPage)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    }

    @ViewBuilder private func subSection(for page: SidebarPage) -> some View {
        switch page {
        case .music:
            MusicSidebarSection()
                .transition(.sidebarDisclosure)
        case .cleanDisk where !vm.categoryCounts.isEmpty:
            categories
                .transition(.sidebarDisclosure)
        default:
            EmptyView()
        }
    }

    private var categories: some View {
        VStack(spacing: 2) {
            CategoryRow(icon: "square.grid.2x2", label: "All", count: vm.artifacts.count, size: formatBytes(vm.totalCleanableSize),
                        color: .blue, isSelected: vm.selectedCategory == nil) {
                vm.selectedCategory = nil
            }
            ForEach(vm.categoryCounts, id: \.0) { cat, count, size in
                CategoryRow(icon: cat.icon, label: cat.displayName, count: count, size: formatBytes(size), color: cat.color,
                            isSelected: vm.selectedCategory == cat) {
                    vm.selectedCategory = cat
                }
            }
        }
        .padding(.leading, 18)
        .padding(.bottom, 4)
    }
}

private struct SidebarGroupHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .tracking(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
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
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? color.opacity(0.9) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
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
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? color.opacity(0.9) : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
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

private struct DisclosureEffect: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .mask(Rectangle().scaleEffect(x: 1, y: progress, anchor: .top))
            .opacity(progress)
    }
}

extension AnyTransition {
    static let sidebarDisclosure = AnyTransition.modifier(active: DisclosureEffect(progress: 0), identity: DisclosureEffect(progress: 1))
}

struct SidebarSubRow: View {
    let label: String
    let icon: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(label)
                    .font(.callout)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(isSelected ? 0.1 : (isHovered ? 0.05 : 0)))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
    }
}
