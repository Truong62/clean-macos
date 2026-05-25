# Sparkle In-Place Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v1.0.2 of Clean macOS with Sparkle in-place auto-update working, so every release after it updates existing installs automatically.

**Architecture:** The real build is XcodeGen (`CleanMacOS/project.yml`) → `xcodebuild`, packaged into a DMG by hand. We generate an EdDSA key pair (private key stays in the macOS Keychain — Sparkle's `sign_update` reads it automatically), embed the public key + feed URL into the app's generated Info.plist, and add a `package.sh` that builds, makes the DMG, EdDSA-signs it, and prints the appcast `<item>` to paste into `docs/appcast.xml` (the GitHub-Pages-served feed). No CI; releases stay manual.

**Tech Stack:** Swift/SwiftUI, Sparkle 2.6, XcodeGen, xcodebuild, hdiutil, Sparkle `generate_keys`/`sign_update` CLI, GitHub Pages.

**Spec:** `docs/superpowers/specs/2026-05-25-sparkle-auto-update-design.md`

---

## File Structure

- `CleanMacOS/project.yml` — add an explicit `info` block carrying the existing Info.plist keys + the three Sparkle keys; this replaces Xcode's auto-generation so custom keys are guaranteed present.
- `CleanMacOS/scripts/package.sh` — **new.** One-command build → DMG → EdDSA-sign → print appcast item. Replaces the stale `release.sh`.
- `CleanMacOS/scripts/generate-keys.sh` — keep; used once in Task 1.
- `CleanMacOS/scripts/release.sh` — **delete** (wrong bundle id, placeholder key, produces .zip not .dmg).
- `CleanMacOS/Makefile` — **delete the `app` target** (wrong bundle id, no Sparkle).
- `appcast.xml` (repo root) — **delete** (never served; the live feed is `docs/appcast.xml`).
- `docs/appcast.xml` — the served feed; receives the new `<item>`.
- `docs/RELEASING.md` — **new.** Per-release checklist + the one-time manual-reinstall note for users.

---

### Task 1: Generate the EdDSA signing key

**Files:** none committed (key material). Public key is consumed in Task 2.

Sparkle's `generate_keys` stores the **private** key in the login Keychain and
prints the **public** key. `sign_update` later reads the private key from the
Keychain automatically — we never handle the private string in scripts.

- [ ] **Step 1: Locate the prebuilt Sparkle tools**

Run:
```bash
cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS
ls .build/artifacts/sparkle/Sparkle/bin/generate_keys .build/artifacts/sparkle/Sparkle/bin/sign_update
```
Expected: both paths print (they exist). If missing, run `swift build` first.

- [ ] **Step 2: Check whether a key already exists**

Run:
```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -p
```
Expected: either prints an existing public key (a key is already in the
Keychain — reuse it, skip Step 3) or prints nothing / an error saying no key
exists.

- [ ] **Step 3: Generate the key pair (only if none existed)**

Run:
```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```
Expected: a message that a key was generated and saved to the Keychain, plus a
line `<dist:edSignature>...`/`SUPublicEDKey` style **public key** (44-char
base64). Copy that public key string — it is needed verbatim in Task 2.

- [ ] **Step 4: Back up the private key offline**

Run:
```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /tmp/sparkle_private_key_BACKUP.txt
```
Then move `/tmp/sparkle_private_key_BACKUP.txt` into a password manager and
delete the temp file. Expected: a file containing the private key is written.
**Do not commit it.** This backup is what lets you sign releases if this Mac dies.

- [ ] **Step 5: Record the public key for the next task**

Keep the public key from Step 2/3 on hand. No commit in this task (key material
must never enter git).

---

### Task 2: Embed Sparkle keys + version into the build

**Files:**
- Modify: `CleanMacOS/project.yml`

XcodeGen currently relies on `GENERATE_INFOPLIST_FILE: YES`, which cannot carry
arbitrary custom keys reliably. Switch to an explicit `info` block so `SUFeedURL`
and `SUPublicEDKey` are guaranteed in the generated plist. The block must
reproduce every key the shipped v1.0.1 plist had, or the app regresses.

- [ ] **Step 1: Replace the target settings/info in `project.yml`**

Replace the `CleanMacOS` target's `settings` block and add an `info` block so the
target reads:

```yaml
targets:
  CleanMacOS:
    type: application
    platform: macOS
    sources:
      - Sources
    dependencies:
      - package: Sparkle
    info:
      path: Sources/Info.plist
      properties:
        CFBundleName: Clean macOS
        CFBundleDisplayName: Clean macOS
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        LSMinimumSystemVersion: "14.0"
        NSPrincipalClass: NSApplication
        NSHighResolutionCapable: true
        LSApplicationCategoryType: public.app-category.utilities
        SUFeedURL: https://truong62.github.io/clean-macos/appcast.xml
        SUPublicEDKey: <PASTE_PUBLIC_KEY_FROM_TASK_1>
        SUEnableAutomaticChecks: true
    settings:
      PRODUCT_BUNDLE_IDENTIFIER: click.ngoctruong.CleanMacOS
      MARKETING_VERSION: "1.0.1"
      CURRENT_PROJECT_VERSION: "2"
      SWIFT_VERSION: "5.9"
      ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
```

(Note `GENERATE_INFOPLIST_FILE` and `INFOPLIST_KEY_LSApplicationCategoryType` are
removed — the `info` block now owns those. Version stays 1.0.1 here; Task 5 bumps it.)

- [ ] **Step 2: Regenerate the Xcode project and build**

Run:
```bash
cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS
xcodegen generate
xcodebuild -project CleanMacOS.xcodeproj -scheme CleanMacOS -configuration Release -derivedDataPath .build/dd build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Verify the built Info.plist (this is the test)**

Run:
```bash
APP=$(find .build/dd/Build/Products/Release -maxdepth 1 -name "*.app" | head -1)
P="$APP/Contents/Info.plist"
for k in SUFeedURL SUPublicEDKey CFBundleShortVersionString CFBundleVersion \
         CFBundleIdentifier LSMinimumSystemVersion NSPrincipalClass; do
  printf "%s = " "$k"; /usr/libexec/PlistBuddy -c "Print :$k" "$P"
done
```
Expected:
- `SUFeedURL = https://truong62.github.io/clean-macos/appcast.xml`
- `SUPublicEDKey = <your public key>`
- `CFBundleShortVersionString = 1.0.1`, `CFBundleVersion = 2`
- `CFBundleIdentifier = click.ngoctruong.CleanMacOS`
- `LSMinimumSystemVersion = 14.0`, `NSPrincipalClass = NSApplication`

If any key errors with "Does Not Exist", add it to `info.properties` and repeat
Steps 2–3.

- [ ] **Step 4: Smoke-test the app launches and Sparkle is wired**

Run:
```bash
open "$APP"
```
Expected: app launches normally; in Settings → Updates, "Check for Updates Now"
is enabled (no crash). Quit the app.

- [ ] **Step 5: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/project.yml CleanMacOS/Sources/Info.plist
git commit -m "feat: embed Sparkle feed URL and EdDSA public key into build"
```

---

### Task 3: Add the packaging + signing script

**Files:**
- Create: `CleanMacOS/scripts/package.sh`

- [ ] **Step 1: Write `package.sh`**

Create `CleanMacOS/scripts/package.sh` with:

```bash
#!/bin/bash
set -euo pipefail

# Usage: ./scripts/package.sh <version>   e.g. ./scripts/package.sh 1.0.2
# Prereq: EdDSA key in Keychain (scripts/generate-keys.sh, one-time).
# Produces: dist/CleanMacOS-<version>.dmg + prints the appcast <item> to paste
#           into docs/appcast.xml. You upload the DMG to the GitHub Release.

VERSION="${1:?Usage: ./scripts/package.sh <version> (e.g. 1.0.2)}"
cd "$(dirname "$0")/.."

APP_NAME="Clean macOS"
GITHUB_REPO="Truong62/clean-macos"
DIST="dist"
DMG="${DIST}/CleanMacOS-${VERSION}.dmg"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"

echo "==> Generating project & building Release..."
xcodegen generate
xcodebuild -project CleanMacOS.xcodeproj -scheme CleanMacOS \
  -configuration Release -derivedDataPath .build/dd build 2>&1 | tail -3
APP=$(find .build/dd/Build/Products/Release -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "build failed: no .app"; exit 1; }

echo "==> Sanity check embedded version..."
PLIST_V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ "$PLIST_V" = "$VERSION" ] || { echo "WARN: app version $PLIST_V != $VERSION (bump project.yml)"; exit 1; }

echo "==> Building DMG..."
rm -rf "$DIST"; mkdir -p "$DIST"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Clean macOS ${VERSION}" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG"
rm -rf "$STAGE"

SIZE=$(stat -f%z "$DMG")

echo "==> EdDSA-signing the DMG (private key from Keychain)..."
SIG_LINE=$("$SIGN_TOOL" "$DMG")   # prints: sparkle:edSignature="..." length="..."

PUBDATE=$(LC_TIME=C date "+%a, %d %b %Y %H:%M:%S %z")
DLURL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/CleanMacOS-${VERSION}.dmg"

cat <<XML

============================================================
  DMG ready: ${DMG} (${SIZE} bytes)
  Paste this <item> into docs/appcast.xml (newest first):
============================================================

    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <description><![CDATA[
        <ul><li>TODO: release notes for ${VERSION}</li></ul>
      ]]></description>
      <enclosure
        url="${DLURL}"
        type="application/octet-stream"
        ${SIG_LINE} />
    </item>

  Next: 1) edit release notes above  2) paste into docs/appcast.xml
        3) gh release create v${VERSION} "${DMG}"  (or upload via web)
        4) commit & push docs/appcast.xml
XML
```

Note: `sign_update` prints both `sparkle:edSignature="..."` and `length="..."`,
so `${SIG_LINE}` supplies the signature and length together inside `<enclosure>`.
`sparkle:version` is omitted from the item, so Sparkle reads the version from the
enclosure's `shortVersionString`/the app; the per-release checklist (Task 5) bumps
`CURRENT_PROJECT_VERSION` which is what Sparkle ultimately compares.

- [ ] **Step 2: Make it executable**

Run:
```bash
chmod +x /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS/scripts/package.sh
```

- [ ] **Step 3: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/scripts/package.sh
git commit -m "feat: add package.sh (build + DMG + EdDSA sign + appcast item)"
```

---

### Task 4: Remove dead/misleading files

**Files:**
- Delete: `appcast.xml` (repo root)
- Delete: `CleanMacOS/scripts/release.sh`
- Modify: `CleanMacOS/Makefile` (drop the broken `app` target)

- [ ] **Step 1: Delete the stale files**

Run:
```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git rm appcast.xml CleanMacOS/scripts/release.sh
```
Expected: both staged for deletion.

- [ ] **Step 2: Remove the `app` target from the Makefile**

Edit `CleanMacOS/Makefile`: delete the `app:` target (lines defining the
hand-rolled Info.plist with bundle id `com.cleanmacos.app`) and remove `app`
from the `.PHONY` line. Keep `build`, `run`, `release`, `clean`. Add a comment:

```make
# Packaging/release is handled by scripts/package.sh (XcodeGen + DMG + Sparkle).
```

- [ ] **Step 3: Verify nothing references the removed files**

Run:
```bash
grep -rn "release.sh\|/appcast.xml\|make app\|\$(APP_DIR)" \
  --include="*.md" --include="*.sh" --include="Makefile" . | grep -v ".build" | grep -v docs/appcast.xml
```
Expected: no stale references (other than historical mentions you choose to fix).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove stale release.sh, root appcast.xml, Makefile app target"
```

---

### Task 5: Build, sign, and stage the v1.0.2 release

**Files:**
- Modify: `CleanMacOS/project.yml` (version bump)
- Modify: `docs/appcast.xml` (add v1.0.2 item)

- [ ] **Step 1: Bump the version**

In `CleanMacOS/project.yml` set:
```yaml
      MARKETING_VERSION: "1.0.2"
      CURRENT_PROJECT_VERSION: "3"
```

- [ ] **Step 2: Run the packaging script**

Run:
```bash
cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS
./scripts/package.sh 1.0.2
```
Expected: `dist/CleanMacOS-1.0.2.dmg` created and an `<item>` block printed with a
real `sparkle:edSignature` and `length`.

- [ ] **Step 3: Verify the signature round-trips (the test)**

Run:
```bash
cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS
PUB=$(.build/artifacts/sparkle/Sparkle/bin/generate_keys -p)
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update dist/CleanMacOS-1.0.2.dmg)
echo "sig: $SIG"
echo "pub: $PUB"
```
Expected: `$SIG` is non-empty and contains `sparkle:edSignature="..."`; `$PUB`
matches the `SUPublicEDKey` embedded in Task 2. (Sparkle verifies this pairing at
update time; matching here confirms the key in the app and the signing key agree.)

- [ ] **Step 4: Paste the item into the feed**

Edit `docs/appcast.xml`: insert the printed `<item>` immediately after the
`<!-- Paste new <item> blocks here when releasing -->` comment (newest first).
Replace the `TODO: release notes` line with the real v1.0.2 notes.

- [ ] **Step 5: Validate the feed is well-formed XML**

Run:
```bash
xmllint --noout /Users/nguyentruong/Desktop/me/clean-macos/docs/appcast.xml && echo "appcast OK"
```
Expected: `appcast OK` (no XML errors).

- [ ] **Step 6: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add CleanMacOS/project.yml docs/appcast.xml
git commit -m "release: v1.0.2 with Sparkle auto-update enabled"
```

---

### Task 6: End-to-end auto-update verification

**Files:** none (verification only). Uses a throwaway local feed + a fake
"newer" build so we don't need to publish twice.

- [ ] **Step 1: Install v1.0.2 to /Applications**

Run:
```bash
hdiutil attach /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS/dist/CleanMacOS-1.0.2.dmg -nobrowse
cp -R "/Volumes/Clean macOS 1.0.2/Clean macOS.app" /Applications/
hdiutil detach "/Volumes/Clean macOS 1.0.2"
```
Expected: `/Applications/Clean macOS.app` exists at version 1.0.2.

- [ ] **Step 2: Build a fake v1.0.3 DMG to update to**

Run: bump `project.yml` to `MARKETING_VERSION 1.0.3` / `CURRENT_PROJECT_VERSION 4`
temporarily, then `./scripts/package.sh 1.0.3`. Revert the version bump in
`project.yml` afterward (do NOT commit it). Expected: `dist/CleanMacOS-1.0.3.dmg`.

- [ ] **Step 3: Serve a local appcast pointing at the 1.0.3 DMG**

Run:
```bash
cd /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS/dist
SIG=$(../.build/artifacts/sparkle/Sparkle/bin/sign_update CleanMacOS-1.0.3.dmg)
cat > appcast-local.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
 <channel><title>local</title>
  <item><title>1.0.3</title>
   <sparkle:shortVersionString>1.0.3</sparkle:shortVersionString>
   <sparkle:version>4</sparkle:version>
   <enclosure url="http://localhost:8000/CleanMacOS-1.0.3.dmg" type="application/octet-stream" ${SIG} />
  </item></channel></rss>
XML
python3 -m http.server 8000 &
```
Expected: server serving the DMG + `appcast-local.xml` on :8000.

- [ ] **Step 4: Point the installed app at the local feed and update**

Run:
```bash
defaults write click.ngoctruong.CleanMacOS SUFeedURL "http://localhost:8000/appcast-local.xml"
open "/Applications/Clean macOS.app"
```
In the app: Settings → Updates → "Check for Updates Now". Expected: Sparkle finds
1.0.3, downloads, **verifies the EdDSA signature**, installs in place, and offers
to relaunch — **without reinstalling**. After relaunch, About shows 1.0.3.

- [ ] **Step 5: Tear down the test**

Run:
```bash
defaults delete click.ngoctruong.CleanMacOS SUFeedURL    # restore embedded feed
kill %1 2>/dev/null    # stop python http.server
rm -f /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS/dist/appcast-local.xml \
      /Users/nguyentruong/Desktop/me/clean-macos/CleanMacOS/dist/CleanMacOS-1.0.3.dmg
```
Expected: clean state; installed app falls back to the embedded production feed.

If Step 4 fails to install (signature rejected / no update found), STOP and debug
before publishing — do not ship a feed the app can't consume.

---

### Task 7: Document the release process

**Files:**
- Create: `docs/RELEASING.md`

- [ ] **Step 1: Write `docs/RELEASING.md`**

```markdown
# Releasing Clean macOS

Auto-update works for **v1.0.2 and later**. The already-shipped v1.0.1 has no
feed URL or public key, so each existing user must install **v1.0.2 once by hand**
(download the DMG, right-click → Open the first time to clear Gatekeeper, drag to
Applications). After that, updates are automatic.

## One-time setup
- EdDSA key is in the Keychain (`scripts/generate-keys.sh`). The private-key
  backup is in the password manager. `SUPublicEDKey` is embedded in `project.yml`.

## Each release
1. Bump `MARKETING_VERSION` (e.g. 1.0.3) **and** `CURRENT_PROJECT_VERSION`
   (monotonic, e.g. 5) in `CleanMacOS/project.yml`. Sparkle compares the build
   number to decide "newer".
2. `cd CleanMacOS && ./scripts/package.sh <version>`
3. Edit the release notes in the printed `<item>` and paste it at the top of the
   item list in `docs/appcast.xml`.
4. `gh release create v<version> CleanMacOS/dist/CleanMacOS-<version>.dmg` (or
   upload the DMG via the GitHub web UI).
5. Commit & push `docs/appcast.xml` and `project.yml` to `main`. GitHub Pages
   serves the updated feed; installed apps update on their next check.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/nguyentruong/Desktop/me/clean-macos
git add docs/RELEASING.md
git commit -m "docs: add release process and auto-update notes"
```

---

## Self-Review Notes

- **Spec coverage:** key gen (T1), embed keys/feed (T2), package+sign script (T3),
  remove dead files (T4), v1.0.2 build+feed (T5), e2e update test (T6), per-release
  + chicken-egg docs (T7). All spec sections covered.
- **Chicken-and-egg:** surfaced in T7 docs and gated — v1.0.1 cannot auto-update;
  one manual v1.0.2 install required.
- **Key safety:** private key never committed; `sign_update` reads it from the
  Keychain; backup goes to a password manager (T1 Step 4).
- **Verification gates:** T2 Step 3 (plist keys), T5 Step 3/5 (sig + XML), T6
  (real in-place update) are the test gates for this non-unit-test work.
