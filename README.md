# Clean macOS

A native macOS app that scans your system for junk files, caches, build artifacts, and other cleanable items — then helps you reclaim disk space safely, with one click.

![Dashboard](https://cdn.shopify.com/s/files/1/0874/1643/9088/files/Screenshot_2026-03-10_at_15.14.35.png?v=1773130510)

## Features

- **Smart Scan** — detects `node_modules`, build outputs, caches, Xcode DerivedData, Docker, iOS backups, VMs and dozens more artifact types
- **Accurate sizing** — measures real on-disk (allocated) size, so sparse files like Docker disk images and VMs aren't wildly over-reported
- **Smart Docker reclaim** — when the Docker daemon is running, prunes unused images, build cache and stopped containers via `docker system prune` (keeps your volumes) instead of nuking the whole VM
- **Homebrew cleanup** — reclaims space with `brew cleanup` instead of breaking your installed formulae
- **Large Files finder** — find the biggest files anywhere, filter by size and age ("older than 6 months"), and send them to the Trash
- **App Uninstaller** — remove an app *and* every file it leaves behind (caches, preferences, containers, logs…) — moved to the Trash, not nuked
- **Personal-data safety** — Photos, Mail, browser profiles, Downloads and the like are flagged, excluded from "Select All", and warned before deletion
- **System cleanup** — root-owned items (system caches, logs, simulator runtimes) are removed via a single macOS admin-password prompt
- **Time Machine snapshots** — detect and delete local APFS snapshots
- **Menu bar + monitoring** — quick access and live system stats from the menu bar
- **Automatic updates** — Sparkle keeps the app up to date and installs new versions **in place**, no reinstall needed

## Categories

Everything found is grouped into five clear buckets:

| Category | What's in it |
|---|---|
| **Developer** | `node_modules`, build outputs, Xcode (DerivedData/Archives/Simulators), Docker, VMs, SDKs |
| **Caches** | App and package-manager caches (npm, pnpm, Cargo, Gradle, pip, Homebrew, VS Code, Slack…) |
| **System** | System/user logs, crash reports, temp files, saved app state, Spotlight index |
| **Media** | Re-downloadable media caches (Apple Podcasts, Apple Music, Spotify) |
| **Personal** | Your own data — backups, Mail, Photos, Movies, Downloads, browser profiles (flagged, never auto-selected) |

## Install

1. Grab the latest `.dmg` from [Releases](https://github.com/Truong62/clean-macos/releases).
2. Open the `.dmg` and drag **Clean macOS** onto the **Applications** folder.
3. The app isn't notarized, so the first launch is blocked by Gatekeeper. Clear it **once**, either way:
   - **Right-click** the app → **Open** → **Open** in the dialog, **or**
   - run:
     ```bash
     xattr -cr "/Applications/CleanMacOS.app"
     ```
4. Open the app normally from then on.

For best results, grant **Full Disk Access** in System Settings → Privacy & Security so the app can measure and clean protected locations.

## Updates

From **v1.0.2 onward** the app updates itself: Sparkle checks the release feed, verifies each update with an EdDSA signature, and installs it **in place** — no download-and-reinstall. You can also trigger a check manually in **Settings → Updates**.

> **Already on v1.0.1?** That build shipped before the updater was wired in, so it can't update itself. Install **v1.0.2 by hand once** (download the DMG, clear Gatekeeper as above). Every version after that updates automatically.

## Build from source

Requires Xcode 16+ / Swift 6.0+ on macOS 14+.

```bash
cd CleanMacOS
swift build -c release      # quick local build
swift run                   # build and run
```

Or open `CleanMacOS.xcodeproj` in Xcode and hit `Cmd + R`.

> The Xcode project is generated with [xcodegen](https://github.com/yonaskolb/XcodeGen) from `project.yml`. After adding or removing source files, run `xcodegen generate` so Xcode picks them up. (`swift build` scans `Sources/` automatically and needs no regeneration.)

## How cleaning works

- **Most items** are deleted directly (caches, build artifacts).
- **Docker / Homebrew** use the right CLI command to reclaim space safely.
- **Personal data** is flagged and requires deliberate selection.
- **System items** are removed via one `osascript ... with administrator privileges` prompt — paths are shell-quoted and gated by a safe-path check.
- **Uninstaller and Large Files** move items to the **Trash**, so you can restore them if needed.

## Releasing

Releases are signed for Sparkle and published to GitHub by hand. In short:

```bash
cd CleanMacOS
# bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml, then:
./scripts/package.sh 1.0.3
```

`package.sh` builds the app, makes the DMG, **signs it with the EdDSA key**, and prints the `<item>` to paste into `docs/appcast.xml`. Then upload that exact DMG to a GitHub Release and push the updated feed. Full steps and gotchas are in [`docs/RELEASING.md`](docs/RELEASING.md).

## Tech stack

- **Swift 6 + SwiftUI** — native macOS app, no Electron, no web views
- **Sparkle 2** — EdDSA-signed auto-update framework
- **FileManager + statfs** — direct filesystem access, no backend
- **Docker / Homebrew CLIs** — for safe, tool-native space reclamation
- **xcodegen** — project generation from `project.yml`
