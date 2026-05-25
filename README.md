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
- **Auto updates** — built-in Sparkle updater

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

### Download

1. Grab the latest `.dmg` from [Releases](https://github.com/Truong62/clean-macos/releases)
2. Open the `.dmg` and drag `Clean macOS.app` to `/Applications`
3. Run this command once to bypass macOS Gatekeeper (the app is unsigned):

```bash
xattr -cr "/Applications/Clean macOS.app"
```

4. Open the app normally

For best results, grant **Full Disk Access** in System Settings → Privacy & Security so the app can measure and clean protected locations.

### Build from source

Requires Xcode 16+ / Swift 6.0+ on macOS 14+.

```bash
cd CleanMacOS
swift build -c release
```

Or open `CleanMacOS.xcodeproj` in Xcode and hit `Cmd + R`.

> The Xcode project is generated with [xcodegen](https://github.com/yonaskolb/XcodeGen). After adding or removing source files, run `xcodegen generate` so Xcode picks them up. (`swift build` scans the `Sources/` folder automatically and needs no regeneration.)

## How cleaning works

- **Most items** are deleted directly (caches, build artifacts).
- **Docker / Homebrew** use the right CLI command to reclaim space safely.
- **Personal data** is flagged and requires deliberate selection.
- **System items** are removed via one `osascript ... with administrator privileges` prompt — paths are shell-quoted and gated by a safe-path check.
- **Uninstaller and Large Files** move items to the **Trash**, so you can restore them if needed.

## Release a new version

```bash
cd CleanMacOS

# One-time: generate the EdDSA signing key (stored in your Keychain), then
# paste the printed public key into project.yml → SUPublicEDKey.
./scripts/generate-keys.sh

# Each release: bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml,
# then build + sign the DMG and print the appcast item:
./scripts/package.sh 1.0.2

# Upload the signed DMG to GitHub
gh release create v1.0.2 dist/CleanMacOS-1.0.2.dmg --title "v1.0.2"

# Paste the printed <item> into docs/appcast.xml, then push
git add docs/appcast.xml project.yml && git commit -m "release v1.0.2" && git push
```

Installed apps (v1.0.2 and later) update **in place** via Sparkle — no reinstall.
See [`docs/RELEASING.md`](docs/RELEASING.md) for the full checklist.

## Tech stack

- **Swift 6 + SwiftUI** — native macOS app, no Electron, no web views
- **Sparkle 2** — auto-update framework
- **FileManager + statfs** — direct filesystem access, no backend
- **Docker / Homebrew CLIs** — for safe, tool-native space reclamation
- **xcodegen** — project generation from `project.yml`

## License

MIT
