# Clean macOS

A native macOS app that scans your system for junk files, caches, build artifacts, and other cleanable items — then helps you reclaim disk space with one click.

![Dashboard](https://cdn.shopify.com/s/files/1/0874/1643/9088/files/Screenshot_2026-03-10_at_15.14.35.png?v=1773130510)

## Features

- **Smart Scan** — detects `node_modules`, build outputs, caches, Xcode DerivedData, Docker images, iOS backups, and 60+ more artifact types
- **Disk Overview** — real-time disk usage with cleanable space visualization
- **Category Filtering** — filter by Dependencies, Build, Cache, Xcode, Docker, System, etc.
- **Time Machine Snapshots** — detect and delete local APFS snapshots
- **Safe Delete** — protected paths, sudo items clearly marked, no accidental system damage
- **Auto Updates** — built-in Sparkle updater, get notified when a new version drops

## Install

### Download

Grab the latest `.zip` from [Releases](https://github.com/sarus/clean-macos/releases), unzip, and drag `Clean macOS.app` to `/Applications`.

### Build from source

Requires Xcode 16+ / Swift 6.0+ on macOS 14+.

```bash
cd CleanMacOS
swift build -c release
```

Or open `CleanMacOS.xcodeproj` in Xcode and hit `Cmd + R`.

## What it scans

| Category | Examples |
|---|---|
| Dependencies | `node_modules`, `vendor`, `.venv`, `Pods`, `.bundle` |
| Build | `dist`, `build`, `.next`, `target`, `.angular` |
| Cache | npm, pnpm, Cargo, Gradle, pip, Homebrew, browser caches |
| Xcode | DerivedData, Archives, iOS DeviceSupport, Simulators |
| Docker | Images, containers, volumes |
| System | User/system caches, logs, crash reports, temp files |
| Media | Spotify cache, Podcasts, Apple Music offline data |
| Backup | iPhone/iPad local backups |
| VMs | Android AVDs, Parallels, VMware, VirtualBox |

## Release a new version

```bash
# One-time: generate signing keys
cd CleanMacOS
./scripts/generate-keys.sh

# Build + package
./scripts/release.sh 1.1.0

# Upload to GitHub
gh release create v1.1.0 .build/release-output/CleanMacOS-1.1.0.zip --title "v1.1.0"

# Update appcast and push
git add appcast.xml && git commit -m "release v1.1.0" && git push
```

Existing users will be notified automatically via Sparkle.

## Tech stack

- **Swift 6 + SwiftUI** — native macOS app, no Electron, no web views
- **Sparkle 2** — auto-update framework
- **FileManager + statfs** — direct filesystem access, no backend needed

## License

MIT
