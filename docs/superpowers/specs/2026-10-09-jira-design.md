# Jira feature — design

Port the standalone `jira-desk` app (Python server + vanilla JS UI + Swift notifier, repo `Truong62/jira-desk`, local copy `~/Avada/jira-desk`) into Clean macOS so `jira-desk` can be deleted. Everything runs inside the app: no Python, no localhost port, no LaunchAgent.

## Goals
- Works with any Jira: user enters the **domain**, auth kind (Server/DC Personal Access Token as `Bearer`, or Cloud email + API token as `Basic`), and token (Keychain).
- Feature parity with jira-desk: Table + Board (drag to change status), filters (assignee/status/app/sprint/month, multi-select, is / is not), parent → sub-task/bug tree, detail panel editing every field, comments, KPI month grouping.
- Native menu bar section (sprint, month progress, Doing / Review & test / To do) and native notifications (added to Assignees, new comment on my task, @mention), click opens the task.

## Architecture (A: reuse the web UI)
The jira-desk web UI (`static/index.html`, `app.js`, `style.css`, logos) is bundled under `Sources/Resources/JiraWeb/` and shown in a `WKWebView`. A `WKURLSchemeHandler` serves `jiradesk://app/...`: static files from the bundle, and `/api/*` routes answered by Swift `JiraService` — the same routes and JSON shapes as the Python server, so `app.js` keeps working with minimal edits.

| File | Responsibility |
|---|---|
| `JiraSettings.swift` | UserDefaults keys + typed getters: domain, auth kind, email, project key, board id, role, field mapping, menu-bar/notification toggles |
| `KeychainStore.swift` | Generic-password save/read/delete (`SecItem`), service name injectable for tests |
| `JiraClient.swift` | URLSession adapter: auth header, `User-Agent: curl/8` (Cloudflare 1010), JSON in/out, `JiraError(status, message)` merging `errorMessages` + `errors`; transport injectable |
| `JiraModels.swift` | Pure mappers ported from `service.py`: summary, detail, update-field builders, pick transition, last sprint parse, parent key (sub-task or bug linked to non-bug), role points, KPI rows parse + "counted elsewhere" merge |
| `JiraFieldDiscovery.swift` | `/rest/api/2/field` → ids for Sprint, Assignees (fallback standard `assignee`), app field, Dev/Tester/BA/Designer Point, Merge Request, Reviewers; user can override |
| `JiraService.swift` | Use cases: list issues (paged, JQL from project + settings), get/update/transition/move/comment, meta (me, board columns, active/future sprints with dates, role), avatar bytes, KPI store |
| `JiraSchemeHandler.swift` | Route table `method + path → service call`; static files; JSON errors with HTTP-like status |
| `JiraWebView.swift` | `NSViewRepresentable` WKWebView with the scheme handler |
| `JiraViewModel.swift` | Snapshot for the menu bar (refresh 60 s, on popover open) — read-only for scenes |
| `JiraNotifications.swift` | Pure event detection (port of `notifications.py`) + 10 s poller + `UNUserNotificationCenter` (guard `Bundle.main.bundleIdentifier`) |
| `JiraMenuBarSection.swift` | Port of jira-desk `notifier/Panel.swift` rendered inside `MenuBarView` when Jira is configured |
| `JiraSettingsSection` (in `SettingsView`) | Domain, auth kind, email, token (SecureField), **Test connection** ("Connected as …"), project + board pickers, role, field mapping, toggles, Import KPI CSV |

Wiring follows the Clipboard feature: `@StateObject` in `CleanMacOSApp`, `.environmentObject`, new `SidebarPage.jira`, `ContentView` case, Settings section. Menu bar gets the Jira view model as `@ObservedObject` (never a binding into an App-observed object — see commit 56ab4c5). New files must be added to `project.yml`/`project.pbxproj` (`xcodegen generate`) and resources to `Package.swift`.

## Behaviour
- Not configured → Jira tab shows "Set up Jira" pointing to Settings; menu bar has no Jira section.
- Default UI state: Table view, All tasks list, Assignee = me, Month = current month.
- Month of an issue: KPI month if the issue is in the imported KPI data, else month of `updated`.
- KPI import: CSV with columns `Month (T9 26), …, Task Link (contains issue key), Dev Point, Tester Point`; optional "counted elsewhere" JQL whose results get a fixed month (Avada: `description ~ "KPI đã tính ở Notion"` → 2026-06). Stored as JSON in Application Support.
- Avatars proxied through `/api/avatar` with auth (anonymous avatar URLs return a default image).

## Errors
Jira errors → JSON `{error}` with the Jira status, shown as toast by the web UI. 401 → banner "Token invalid — open Settings". Offline → menu bar shows "Offline".

## Testing
XCTest: mappers and event detection (port the 32 Python tests), scheme-handler routing with a fake transport, Keychain with a test service name. Manual check against a real Jira is **read-only** (no writes).

## Phases
1. Core: settings, Keychain, client, models, discovery, service, scheme handler, web bundle, Jira tab, Settings section.
2. Menu bar section + notifications.
3. Board drag-and-drop + full parity pass against jira-desk.
4. KPI import + month grouping.
5. Cleanup (asked first): uninstall jira-desk agents/notifier/Desktop launcher, delete GitHub repo and local folder.
