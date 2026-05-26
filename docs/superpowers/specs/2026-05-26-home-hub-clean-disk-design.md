# Home Hub + Clean Disk Tab — Design Spec

- **Date:** 2026-05-26
- **Status:** Approved (design), pending implementation plan
- **Branch:** `feat/clipboard-history` (continues — Home hub references the Clipboard tab)

## Problem

Today the **Home** page *is* the disk cleaner: it bundles the disk dashboard,
the Scan/Clean toolbar, the artifact table, snapshots, and a status bar. The
user wants Home to instead be an attractive **hub** that routes to each feature,
and to move the scan/clean workflow into its own **Clean Disk** tab.

## Goals

1. Turn **Home** into a hub: a hero with the primary "Scan & Clean Disk" call to
   action + disk usage overview, and small cards that navigate to the other
   features.
2. Add a **Clean Disk** tab that holds the current Home scan/clean workflow,
   unchanged in behavior.
3. No functional regression to scanning/cleaning — only relocation + a new hub.

## Non-goals

- No change to scan/clean logic, large files, uninstall, or clipboard behavior.
- No new cleaning capability (Clean Disk = the existing workflow, relocated).
- No unit tests for views (matches the project's existing pattern).

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Home vs Clean Disk | Move existing Scan/Clean into a new **Clean Disk** tab; Home becomes a hub |
| Home layout | **Hero CTA + small feature cards** (large primary action, small cards below) |
| CATEGORIES sidebar section | Shows under **Clean Disk** (was Home) |
| Branch | Continue on `feat/clipboard-history` |

## Navigation structure

Sidebar order: **Home · Clean Disk · Large Files · Uninstall Apps · Clipboard ·
Settings · About**.

`SidebarPage` gains a `.cleanDisk` case. `ContentView` owns `currentPage`
(`@State`). `HomeView` receives a `navigate: (SidebarPage) -> Void` closure so
its hero/cards can switch tabs.

## Home hub — `HomeView.swift`

**Hero (top):**
- Reuses `DiskUsageBar` for the disk overview + free space.
- Headline + primary button driven by scan state:
  - Not scanned yet (`vm.artifacts.isEmpty`): headline "Scan your disk to find
    junk"; button **"Scan & Clean Disk"**.
  - Scanned with cleanable: headline "**\(formatBytes(vm.totalCleanableSize))**
    ready to clean"; button **"Review & Clean"**.
  - While scanning (`vm.isScanning`): button shows a `ProgressView` and is
    disabled.
- Button action: `navigate(.cleanDisk)`, and if `vm.artifacts.isEmpty` also
  `Task { await vm.scan() }`.

**Feature cards (below, small):** each is a button that calls `navigate(_:)`:
- 📄 **Large Files** → `.largeFiles` — subtitle "Find big files".
- 🗑 **Uninstall Apps** → `.uninstall` — subtitle "Remove apps + leftovers".
- 📋 **Clipboard** → `.clipboard` — subtitle "\(clipboard.items.count) items"
  (reads `@EnvironmentObject clipboard: ClipboardViewModel`).

Styling follows existing idioms: `.ultraThinMaterial` cards, `RoundedRectangle`
corners, `.gradient` icon fills, hover highlight like `SidebarItem`.

## Clean Disk tab — `CleanDiskView.swift`

Holds exactly what `ContentView`'s `case .home` renders today:

```
VStack(spacing: 0) {
    DashboardView()
    ToolbarRow()
    Divider().opacity(0.5)
    ArtifactTableView()
    if !vm.snapshots.isEmpty { SnapshotSection() }
    StatusBar()
}
.background(Color(nsColor: .windowBackgroundColor))
```

`ToolbarRow`, `StatusBar`, `CategoryChip` remain defined in `ContentView.swift`
(shared, same module) — `CleanDiskView` composes them.

## ContentView routing

```
case .home:      HomeView(navigate: { currentPage = $0 })
case .cleanDisk: CleanDiskView()
```

The `.home` block no longer inlines the dashboard/table; that moves to
`CleanDiskView`.

## SidebarView changes

- Add a `SidebarItem` "Clean Disk" (icon `internaldrive.fill`, color `.teal`)
  between Home and Large Files.
- The CATEGORIES block condition changes from `currentPage == .home` to
  `currentPage == .cleanDisk`.

## Error handling & edge cases

- Not yet scanned → hero invites scanning; never shows a bare "0".
- `vm.diskInfo == nil` (still loading) → `DiskUsageBar` is omitted / placeholders
  shown, same as today's Dashboard behavior.
- Scanning in progress → CTA shows loading + disabled (reuse `vm.isScanning`).
- `Cmd+R` "Scan" global command keeps working as-is (scans on the shared `vm`);
  results appear when the Clean Disk tab is opened. (No coordination change.)

## Testing

UI composition + navigation only — no unit tests (project has none for views).
Verify by building and manually: each sidebar tab opens correctly; the Home
hero CTA navigates to Clean Disk and starts a scan when none has run; feature
cards navigate to the right tabs; the Clipboard card shows the live item count;
the CATEGORIES list now appears under Clean Disk.
