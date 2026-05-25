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

## Releasing a new version

Releases are signed for Sparkle and published to GitHub by hand. `scripts/package.sh` handles the build and signing; you do the version bump, the appcast paste, and the upload. The steps below release `1.0.3` as an example.

> ⚠️ **Creating a GitHub Release is not enough on its own.** The app reads the **appcast feed** (`docs/appcast.xml`), not the Releases page. If you upload a new DMG but skip steps 3–4 below, installed apps will keep reporting *"you're up to date."* Every release must add an `<item>` to the feed.

### 1. Bump the version

In `CleanMacOS/project.yml`, raise **both** values:

```yaml
      MARKETING_VERSION: "1.0.3"      # user-facing version
      CURRENT_PROJECT_VERSION: "4"    # build number — MUST increase every release
```

Sparkle compares the build number to decide "newer". If `CURRENT_PROJECT_VERSION` doesn't go up, no update is offered — even if the marketing version changed.

### 2. Build + sign (one command)

```bash
cd CleanMacOS
./scripts/package.sh 1.0.3
```

This builds the app, creates `dist/CleanMacOS-1.0.3.dmg`, **EdDSA-signs it** (there is no separate signing step — the script does it), and prints an `<item>` block containing the signature and file size.

### 3. Add the item to the feed

Copy the printed `<item>…</item>` and paste it at the **top** of the item list in `docs/appcast.xml` (newest first, above the previous version). Replace the `TODO` line with real release notes.

### 4. Commit + push the feed

```bash
git add CleanMacOS/project.yml docs/appcast.xml
git commit -m "release v1.0.3"
git push
```

### 5. Publish the DMG on GitHub

```bash
open -R CleanMacOS/dist/CleanMacOS-1.0.3.dmg   # reveals the exact file in Finder
```

Open `https://github.com/Truong62/clean-macos/releases/new?tag=v1.0.3`, drag **that file** into the release's assets, set the title to `v1.0.3`, and **Publish**.

> ⚠️ **Upload the DMG that `package.sh` produced — do not rebuild, rename, or re-zip it.** The appcast signature is tied to those exact bytes; changing a single byte makes installed apps reject the update. The filename must stay `CleanMacOS-1.0.3.dmg` to match the `url` in the appcast item.

Installed apps (v1.0.2+) pick up the update on their next check. The one-time v1.0.1 migration and signing-key handling are documented in [`docs/RELEASING.md`](docs/RELEASING.md).

### Hướng dẫn release (tiếng Việt)

Các bước đưa một phiên bản mới lên GitHub (ví dụ lên **v1.0.3**):

> ⚠️ **Chỉ tạo Release trên GitHub là CHƯA ĐỦ.** App đọc **feed `docs/appcast.xml`**, không đọc trang Releases. Nếu upload DMG mới mà bỏ qua bước 3–4 dưới đây, app sẽ vẫn báo *"bản mới nhất"*. Lần nào release cũng PHẢI thêm `<item>` vào feed.

1. **Sửa version** trong `CleanMacOS/project.yml` — tăng **cả hai** dòng:
   ```yaml
         MARKETING_VERSION: "1.0.3"      # bản người dùng nhìn thấy
         CURRENT_PROJECT_VERSION: "4"    # số build — LẦN NÀO CŨNG PHẢI +1
   ```
   Sparkle so `CURRENT_PROJECT_VERSION` để biết bản nào mới hơn; quên tăng là không ai được mời update.

2. **Build + ký** (1 lệnh, script tự ký — không phải bấm gì thêm):
   ```bash
   cd CleanMacOS
   ./scripts/package.sh 1.0.3
   ```
   Script tạo `dist/CleanMacOS-1.0.3.dmg`, ký bằng khoá EdDSA, và **in ra một khối `<item>`** (có sẵn chữ ký + dung lượng).

3. **Dán khối `<item>`** vừa in vào **trên cùng** danh sách trong `docs/appcast.xml` (mới nhất ở trên, phía trên item của bản trước), rồi sửa dòng `TODO` thành ghi chú thật.

4. **Đưa lên git:**
   ```bash
   cd ..
   git add CleanMacOS/project.yml docs/appcast.xml
   git commit -m "release v1.0.3"
   git push
   ```
   > Nếu push báo `Permission denied (publickey)`: SSH key chưa nạp vào agent. Chạy
   > `ssh-add ~/.ssh/id_ed25519_ngoctruong` (nhập passphrase) rồi `git push` lại.

5. **Tạo Release trên GitHub + upload DMG:**
   ```bash
   open -R CleanMacOS/dist/CleanMacOS-1.0.3.dmg   # mở Finder, chọn sẵn đúng file
   ```
   Mở `https://github.com/Truong62/clean-macos/releases/new?tag=v1.0.3`, kéo **đúng file đó** vào phần assets, đặt title `v1.0.3`, bấm **Publish**.

   > ⚠️ Upload **đúng file `package.sh` vừa tạo** — đừng build lại, đừng đổi tên, đừng nén lại. Chữ ký gắn với từng byte của file; sai 1 byte là app từ chối update. Tên file phải giữ nguyên `CleanMacOS-1.0.3.dmg` để khớp URL trong appcast.

Xong. App của bạn bè (v1.0.2 trở lên) lần kiểm tra kế tiếp sẽ tự tải và cài v1.0.3 tại chỗ.

## Tech stack

- **Swift 6 + SwiftUI** — native macOS app, no Electron, no web views
- **Sparkle 2** — EdDSA-signed auto-update framework
- **FileManager + statfs** — direct filesystem access, no backend
- **Docker / Homebrew CLIs** — for safe, tool-native space reclamation
- **xcodegen** — project generation from `project.yml`
