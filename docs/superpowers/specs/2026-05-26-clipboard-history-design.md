# Clipboard History — Design Spec

- **Date:** 2026-05-26
- **Status:** Approved (design), pending implementation plan
- **Author:** Truong62 + Claude

## Problem

Clean macOS is a junk-cleaner utility. The user wants to add a **clipboard
history** feature so that copying something new no longer destroys the previous
clipboard contents. Today macOS keeps only the last copied item; the user wants
to browse what they copied earlier and reuse any of it quickly from anywhere.

## Goals

1. Capture text copied to the clipboard while the app is running, into a history.
2. Browse / manage that history in a **Clipboard tab** in the main window:
   columns **Name** (preview) / **Date** / **Actions** (Copy, Delete), plus
   search and Clear All.
3. Reuse any past item from **anywhere** via a global hotkey (default `⌘⇧V`):
   a floating panel appears, the user picks an item, and it is **auto-pasted**
   into the frontmost app.

## Non-goals (for this version)

- Images and files in history — **coming soon**, explicitly out of scope now.
  Only `String`-type pasteboard content is captured.
- Syncing history across devices / iCloud.
- Pinned / favorite items, tags, smart categories.
- Capturing history while the app is **not** running (the app process must be
  alive; documented as expected behavior).

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Content types | **Text only** for now (images/files later) |
| Persistence | **Both**, user-selectable via a Settings toggle (default: persist) |
| Sensitive data | **Store everything** by default; optional "skip concealed" toggle (default off) |
| Hotkey behavior | **Full**: floating panel + auto-paste, with graceful copy-only fallback |
| Hotkey library | **KeyboardShortcuts** SPM package (Sindre Sorhus) for capture + customizable recorder |

## User-facing behavior

- **Background capture:** a poller reads `NSPasteboard.general.changeCount`
  every ~0.5s. On a new text value, it is inserted at the top of the history.
  Duplicate of an existing item ⇒ move that item to the top instead of adding a
  copy (dedup).
- **Clipboard tab** (new sidebar item, icon `doc.on.clipboard`):
  - Table rows: **Name** = single-line truncated preview; **Date** = relative
    time (e.g. "2 minutes ago"); **Actions** = Copy button + Delete button.
  - A **search field** filters by substring.
  - A **Clear All** button empties the history (with a confirm).
  - Empty state explains that history fills as you copy, and that images/files
    are coming soon.
- **Global hotkey `⌘⇧V`** (default, user-changeable):
  - Shows a centered, borderless floating **NSPanel**.
  - Search field focused; list navigable with **↑ / ↓**; **Enter** selects;
    **Esc** dismisses.
  - On select: write to `NSPasteboard` → close panel → **auto-paste** by
    synthesizing `⌘V` (only if Accessibility is granted). If not granted, the
    item stays on the clipboard for a manual paste and a one-time hint offers to
    open Accessibility settings.

## Architecture & components

Follows the existing `Service` + `ViewModel` + `View` convention. New files in
`CleanMacOS/Sources/`:

| File | Responsibility |
|---|---|
| `ClipboardItem.swift` | Model: `id: UUID`, `text: String`, `createdAt: Date`. `Codable`, `Identifiable`, `Hashable`. Computed `preview` (single-line, length-capped). |
| `ClipboardMonitor.swift` | Polls `changeCount` on a timer; reads `.string`; calls back with every new text value (the app's own writes are reconciled downstream by dedup, not specially suppressed here). |
| `ClipboardViewModel.swift` | Central `ObservableObject`. `@Published items`; logic for add/dedup/cap; `copy(_:)`, `delete(_:)`, `clearAll()`; reads settings; orchestrates load/save. Owns the `ClipboardMonitor`. |
| `ClipboardStore.swift` | Pure persistence helper: load/save `[ClipboardItem]` as JSON at `~/Library/Application Support/CleanMacOS/clipboard-history.json`. Kept separate for testability. |
| `ClipboardHistoryView.swift` | The Clipboard tab UI: table (Name/Date/Actions) + search + Clear All + empty state. |
| `PasteService.swift` | Synthesizes `⌘V` via `CGEvent`; checks `AXIsProcessTrusted()`; can open the Accessibility pane in System Settings. |
| `ClipboardPanelController.swift` | Owns the floating `NSPanel`; show/hide/toggle; hosts the panel SwiftUI view; performs select → copy → paste. |
| `ClipboardPanelView.swift` | SwiftUI content of the panel: searchable list with keyboard navigation. |
| `GlobalShortcuts.swift` | `KeyboardShortcuts.Name` definitions (e.g. `.showClipboardHistory`). |

**Modified files:**

- `SidebarView.swift` — add `case clipboard` to `SidebarPage`; add a sidebar item.
- `ContentView.swift` — route `.clipboard` → `ClipboardHistoryView`.
- `SettingsView.swift` — add the clipboard settings section (below).
- `CleanMacOSApp.swift` — create `ClipboardViewModel` as `@StateObject`, inject
  via `.environmentObject`; register the global hotkey at launch; own the
  `ClipboardPanelController`.
- `Package.swift` + `project.yml` — add the `KeyboardShortcuts` SPM dependency.

**Lifecycle:** `ClipboardViewModel` is a `@StateObject` in `CleanMacOSApp`,
injected as an `environmentObject` so the tab shares the same instance. It owns
the `ClipboardMonitor`, which runs for the whole app lifetime. The
`ClipboardPanelController` holds a reference to the same view model. The hotkey
is registered at app launch and toggles the panel.

## Data flow

```
[Timer ~0.5s] → changeCount changed? → read .string
   → ClipboardViewModel.add(text)
       → duplicate of existing? move to top : insert at top
       → trim to cap (default 200)
       → if persist enabled: ClipboardStore.save() (debounced)
   → @Published items updates → tab re-renders

[Tab] Copy   → NSPasteboard.setString (monitor ignores self-write)
[Tab] Delete / Clear All → mutate items → save

[⌘⇧V] → panel shows → ↑↓ select → Enter
   → NSPasteboard.setString → close panel
   → PasteService.paste(): trusted? synthesize ⌘V : no-op + one-time hint
```

## Persistence & settings

New section in the Settings tab, all via `@AppStorage`:

- **"Keep history after quitting app"** — `clipboardPersist` (default **on**).
  When off, delete the JSON file and keep history in RAM only.
- **"Maximum items"** — `clipboardMaxItems` (default **200**). Oldest items are
  trimmed beyond the cap.
- **Hotkey recorder** — `KeyboardShortcuts.Recorder` to view/change the shortcut
  (default `⌘⇧V`).
- **Auto-paste status** — shows whether Accessibility is granted, with a button
  to open System Settings → Privacy & Security → Accessibility.
- **"Skip passwords"** — `clipboardSkipConcealed` (default **off**, per user
  choice). When on, skips pasteboard content flagged
  `org.nspasteboard.ConcealedType` / `TransientType`.

## Error handling & edge cases

- Empty / whitespace-only clipboard → skipped.
- Non-string clipboard (image/file) → ignored for now (images/files later).
- **Self-write:** when the app calls `setString` on Copy, the next poll sees
  that text and dedup moves the existing item to the top — no duplicate row.
  This is the single reconciliation point (the monitor does not special-case
  self-writes).
- **Accessibility not granted:** auto-paste is a no-op; the content remains on
  the clipboard for manual paste; a one-time hint offers to open settings.
- **App not running:** nothing is captured (expected; documented in README).
- Very large text item (e.g. > 1 MB) → still stored, preview truncated; the
  count cap still applies.
- All `@Published` mutations are dispatched on the main thread.

## Testing

The project currently has **no test target**.

- **Unit tests:** extract the pure logic (dedup, cap/trim, JSON round-trip) into
  `ClipboardViewModel` / `ClipboardStore` so it is testable without UI. Add a
  small test target. Per TDD, write these tests before the implementation.
  - dedup: adding an existing text moves it to the top, no duplicate.
  - cap: adding beyond `maxItems` trims the oldest.
  - persistence: save → load round-trips identical items.
  - persist toggle off: file is removed, in-memory history preserved.
- **Manual test checklist** (UI / hotkey / paste / permission — not automated):
  1. Copy several text snippets in another app → they appear, newest first.
  2. Copy a duplicate → it moves to the top, no second row.
  3. Search filters the list; Clear All empties it (after confirm).
  4. Click Copy on a row → ⌘V in another app pastes that text.
  5. Press `⌘⇧V` anywhere → panel opens, ↑↓ + Enter selects.
  6. With Accessibility granted → selection auto-pastes into the frontmost app.
  7. Without Accessibility → selection copies only + hint appears.
  8. Toggle persist off → quit/reopen → history empty; on → history survives.
  9. Change the hotkey in Settings → new shortcut works, old one doesn't.

## Distribution notes

- The app is **ad-hoc signed, not sandboxed** — clipboard polling and global
  hotkeys work without entitlement changes.
- Auto-paste requires the user to grant **Accessibility** once in System
  Settings; the feature degrades gracefully without it.
- README should document: history is captured only while the app runs, and
  auto-paste needs Accessibility.
