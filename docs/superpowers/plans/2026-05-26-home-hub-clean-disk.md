# Home Hub + Clean Disk Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the existing Scan/Clean workflow into a new **Clean Disk** tab and turn **Home** into a hub (hero CTA + disk overview + small feature cards that navigate to other tabs).

**Architecture:** Extract the current `ContentView` `.home` body into a new `CleanDiskView`. Add a `.cleanDisk` page. Build a new `HomeView` hub that takes a `navigate: (SidebarPage) -> Void` closure and reads `AppViewModel` (disk/cleanable) + `ClipboardViewModel` (item count) from the environment. Reuse existing `DiskUsageBar`, `ToolbarRow`, `StatusBar`.

**Tech Stack:** Swift 5.9, SwiftUI, macOS 14, Swift Package Manager, XcodeGen.

**Build/verify commands** run from `CleanMacOS/` and must use Xcode's toolchain:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
After adding source files, run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate`.

**No view unit tests** — matches the project's existing pattern. Verification is build + manual.

---

## File Structure

| File | Responsibility |
|---|---|
| `CleanDiskView.swift` (new) | Wraps the current Home scan/clean stack (Dashboard/Toolbar/Table/Snapshots/Status). |
| `HomeView.swift` (new) | The hub: hero CTA + `DiskUsageBar` + 3 feature cards; navigates via a closure. |
| `SidebarView.swift` (modify) | Add `.cleanDisk` case + sidebar item; move CATEGORIES condition to `.cleanDisk`. |
| `ContentView.swift` (modify) | Route `.cleanDisk → CleanDiskView`, `.home → HomeView`. Keep `ToolbarRow`/`StatusBar`/`CategoryChip`. |

---

## Task 1: Add the Clean Disk tab (move scan/clean out of Home)

**Files:**
- Create: `CleanMacOS/Sources/CleanDiskView.swift`
- Modify: `CleanMacOS/Sources/SidebarView.swift`
- Modify: `CleanMacOS/Sources/ContentView.swift`

- [ ] **Step 1: Create `CleanDiskView`**

Create `CleanMacOS/Sources/CleanDiskView.swift`:

```swift
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
```

- [ ] **Step 2: Add `.cleanDisk` to `SidebarPage` and a sidebar item**

In `CleanMacOS/Sources/SidebarView.swift`, change the enum to:

```swift
enum SidebarPage: Hashable {
    case home
    case cleanDisk
    case largeFiles
    case uninstall
    case clipboard
    case settings
    case about
}
```

Then add a `SidebarItem` immediately after the Home item (before "Large Files"):

```swift
                SidebarItem(icon: "internaldrive.fill", label: "Clean Disk", color: .teal, isSelected: currentPage == .cleanDisk) {
                    currentPage = .cleanDisk
                }
```

- [ ] **Step 3: Route `.cleanDisk` in `ContentView`**

In `CleanMacOS/Sources/ContentView.swift`, add a case after the `.home` block (keep `.home` as-is for now):

```swift
            case .cleanDisk:
                CleanDiskView()
```

- [ ] **Step 4: Regenerate project and build**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/CleanDiskView.swift CleanMacOS/Sources/SidebarView.swift CleanMacOS/Sources/ContentView.swift CleanMacOS/CleanMacOS.xcodeproj/project.pbxproj
git commit -m "feat: add Clean Disk tab with the scan/clean workflow"
```

---

## Task 2: Turn Home into the hub

**Files:**
- Create: `CleanMacOS/Sources/HomeView.swift`
- Modify: `CleanMacOS/Sources/ContentView.swift`
- Modify: `CleanMacOS/Sources/SidebarView.swift`

- [ ] **Step 1: Create `HomeView`**

Create `CleanMacOS/Sources/HomeView.swift`:

```swift
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var vm: AppViewModel
    @EnvironmentObject var clipboard: ClipboardViewModel
    let navigate: (SidebarPage) -> Void

    private var hasResults: Bool { !vm.artifacts.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                featureCards
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var hero: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(.purple.gradient)
                if hasResults {
                    Text("\(formatBytes(vm.totalCleanableSize)) ready to clean")
                        .font(.title).fontWeight(.bold).fontDesign(.rounded)
                } else {
                    Text("Scan your disk to find junk")
                        .font(.title2).fontWeight(.semibold)
                }
            }

            Button {
                navigate(.cleanDisk)
                if !hasResults { Task { await vm.scan() } }
            } label: {
                HStack(spacing: 6) {
                    if vm.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: hasResults ? "trash.fill" : "magnifyingglass")
                    }
                    Text(hasResults ? "Review & Clean" : "Scan & Clean Disk")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.purple)
            .disabled(vm.isScanning)

            if let info = vm.diskInfo {
                DiskUsageBar(info: info, cleanableSize: vm.totalCleanableSize)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1))
    }

    private var featureCards: some View {
        HStack(spacing: 12) {
            FeatureCard(icon: "doc.text.magnifyingglass", title: "Large Files",
                        subtitle: "Find big files", color: .orange) { navigate(.largeFiles) }
            FeatureCard(icon: "trash.fill", title: "Uninstall Apps",
                        subtitle: "Remove apps + leftovers", color: .red) { navigate(.uninstall) }
            FeatureCard(icon: "doc.on.clipboard.fill", title: "Clipboard",
                        subtitle: "\(clipboard.items.count) items", color: .indigo) { navigate(.clipboard) }
        }
    }
}

private struct FeatureCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(color.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(hovered ? color.opacity(0.5) : color.opacity(0.15), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
```

- [ ] **Step 2: Route `.home` to `HomeView` in `ContentView`**

In `CleanMacOS/Sources/ContentView.swift`, replace the entire `.home` case body (the `VStack { DashboardView() … StatusBar() }.background(...)`) with:

```swift
            case .home:
                HomeView(navigate: { currentPage = $0 })
```

- [ ] **Step 3: Move the CATEGORIES sidebar section to Clean Disk**

In `CleanMacOS/Sources/SidebarView.swift`, change the condition that gates the CATEGORIES block from:

```swift
            if currentPage == .home && !vm.categoryCounts.isEmpty {
```

to:

```swift
            if currentPage == .cleanDisk && !vm.categoryCounts.isEmpty {
```

- [ ] **Step 4: Regenerate project and build**

Run: `cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`
Expected: Build succeeds.

- [ ] **Step 5: Manual verification**

Build and run the app (see "Build/verify" note; the maintainer typically runs from Xcode or via `xcodebuild -scheme CleanMacOS`). Then:
1. **Home** shows the hero with "Scan your disk to find junk" + "Scan & Clean Disk" button, the disk usage bar, and three feature cards.
2. Click **Scan & Clean Disk** → switches to the **Clean Disk** tab and a scan starts.
3. After the scan, return to **Home** → hero now reads "X GB ready to clean" with a "Review & Clean" button that returns to Clean Disk.
4. The **Clipboard** card shows the live item count; clicking each card opens the matching tab.
5. The **CATEGORIES** list in the sidebar now appears only on the **Clean Disk** tab.

- [ ] **Step 6: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/Sources/HomeView.swift CleanMacOS/Sources/ContentView.swift CleanMacOS/Sources/SidebarView.swift CleanMacOS/CleanMacOS.xcodeproj/project.pbxproj
git commit -m "feat: turn Home into a hub that routes to features"
```

---

## Notes for the executor

- `ToolbarRow`, `StatusBar`, and `CategoryChip` stay defined in `ContentView.swift` (shared in the same module); `CleanDiskView` and others reference them directly.
- `formatBytes`, `DiskUsageBar`, `DashboardView`, `ArtifactTableView`, `SnapshotSection` already exist — reuse, do not redefine.
- Do not change scan/clean logic in `AppViewModel`; this is a relocation + new hub only.
- Don't bump the app version or touch the appcast.
```
