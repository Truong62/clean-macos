import SwiftUI

enum SidebarPage: Hashable {
    case home
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

            if currentPage == .home && !vm.categoryCounts.isEmpty {
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.85) : isHovered ? Color.gray.opacity(0.1) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color.opacity(0.8) : isHovered ? Color.gray.opacity(0.1) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
