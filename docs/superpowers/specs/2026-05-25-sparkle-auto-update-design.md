# Sparkle In-Place Auto-Update — Design

**Date:** 2026-05-25
**Status:** Approved (design), pending implementation
**Goal:** Existing installs of Clean macOS update themselves in place when a new
version is published on GitHub, instead of users deleting and reinstalling.

## Context & Constraints

- **Distribution:** small audience (2–3 friends), not the Mac App Store.
- **No Apple Developer account.** No Developer ID code signing or notarization.
  The app ships **ad-hoc / linker-signed** only. → Use Sparkle's **EdDSA
  signature** mechanism as the trust root. First install still requires the user
  to right-click → Open once to clear Gatekeeper quarantine (acceptable at this
  scale). In-place updates after that do not re-prompt.
- **Manual release.** The author builds and uploads the DMG to GitHub by hand
  (create tag → build → drag DMG to GitHub Releases web UI). **No CI is wanted.**
- **Real build pipeline:** XcodeGen (`CleanMacOS/project.yml`) → `xcodebuild`,
  bundle id `click.ngoctruong.CleanMacOS`, `GENERATE_INFOPLIST_FILE: YES`.
  DMG is created manually with `hdiutil`.
- **Appcast hosting:** GitHub Pages serves from `main` branch `/docs`. The live
  feed is therefore `docs/appcast.xml` at
  `https://truong62.github.io/clean-macos/appcast.xml`.

## Root-Cause Diagnosis

Inspection of the shipped `CleanMacOS-1.0.1.dmg` shows its `Info.plist`:

- **has no `SUFeedURL`** — Sparkle has nowhere to check for updates;
- **has no `SUPublicEDKey`** — no key to verify any update;
- is ad-hoc / linker-signed; Sparkle.framework is embedded but inert.

The repo contains three inconsistent, unused build configs that do **not** match
the shipped app and are a source of confusion:

- `CleanMacOS/Makefile` (`app` target): bundle id `com.cleanmacos.app`, version
  hardcoded `1.0.0`, no Sparkle keys, **does not copy Sparkle.framework**.
- `CleanMacOS/scripts/release.sh`: bundle id `com.sarus.CleanMacOS`, placeholder
  `SUPublicEDKey = REPLACE_WITH_YOUR_PUBLIC_KEY`, produces a **.zip** (shipped
  artifact is a `.dmg`).
- Root `appcast.xml` — a duplicate of `docs/appcast.xml` that is **never served**
  (Pages reads `/docs`). `release.sh` tells the user to "push appcast.xml"
  without saying which; editing the root copy does nothing.

## The Chicken-and-Egg Limitation (must be communicated)

Auto-update **cannot be applied retroactively** to v1.0.1, because that build has
no feed URL and no public key — it has no mechanism to discover or trust an
update. Therefore:

1. We embed `SUFeedURL` + `SUPublicEDKey` into the build and ship **v1.0.2**.
2. Each existing user installs **v1.0.2 manually one final time** (download DMG,
   replace app in `/Applications`).
3. From **v1.0.2 onward**, every later release auto-updates in place.

This one-time manual reinstall is unavoidable and must be told to the users.

## Design

### 1. Generate the EdDSA key pair (one-time)

Run `CleanMacOS/scripts/generate-keys.sh` (already present; it invokes Sparkle's
`generate_keys` tool). Outcome:

- **Private key** — stored securely outside the repo (password manager / Keychain
  via `--account`). Used to sign every release. **Never committed.**
- **Public key** — base64 string embedded in the app (step 2). Safe to commit.

### 2. Embed Sparkle keys into the real build (`project.yml`)

Add to the `CleanMacOS` target so XcodeGen writes them into the generated
`Info.plist`:

```yaml
    info:
      path: Sources/Info.plist        # XcodeGen generates this; sets INFOPLIST_FILE
      properties:
        SUFeedURL: https://truong62.github.io/clean-macos/appcast.xml
        SUPublicEDKey: <PUBLIC_KEY_FROM_STEP_1>
        SUEnableAutomaticChecks: true
        # plus the keys Xcode used to auto-generate: CFBundleName, LSUIElement,
        # NSHighResolutionCapable, LSApplicationCategoryType, icon name, etc.
```

When a target uses `info.properties`, XcodeGen sets `INFOPLIST_FILE` and stops
auto-generating, so all previously auto-generated keys must be carried over to
avoid regressions. Verify the generated bundle's `Info.plist` matches v1.0.1
plus the three Sparkle keys.

> Note: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` remain build settings in
> `project.yml`; they continue to populate `CFBundleShortVersionString` /
> `CFBundleVersion`.

### 3. Remove the misleading dead files

- Delete the root `appcast.xml` (the served feed is `docs/appcast.xml`).
- Delete or neutralize `CleanMacOS/Makefile`'s `app` target and
  `CleanMacOS/scripts/release.sh`, replaced by `scripts/package.sh` (step 4).
  Keep `dev.sh` and `generate-keys.sh`.

### 4. New packaging script (`CleanMacOS/scripts/package.sh`)

Matches the actual XcodeGen + manual-DMG flow. Given a version, it:

1. `xcodegen generate` (ensure project is current), then
   `xcodebuild -scheme CleanMacOS -configuration Release` → built `.app`.
2. Build the **DMG** with `hdiutil` (app + `/Applications` symlink, volume name
   `Clean macOS <version>`), matching the current manual layout.
3. **EdDSA-sign the DMG** with Sparkle's `sign_update` tool using the private key
   (read from env var or Keychain, never hardcoded).
4. Print a ready-to-paste appcast `<item>` containing the download URL
   (`.../releases/download/v<version>/CleanMacOS-<version>.dmg`), `length`
   (file size), `sparkle:version` (= `CFBundleVersion`),
   `sparkle:shortVersionString` (= marketing version), `pubDate`, and
   `sparkle:edSignature`.

The author still uploads the DMG to the GitHub Release and pastes the `<item>`
into `docs/appcast.xml` by hand — no automation beyond the script's output.

**Artifact decision:** keep **DMG only**. Sparkle 2 installs in-place from a DMG
containing a single app, so a second ZIP artifact is unnecessary (YAGNI).

### 5. Per-release checklist (documented)

1. Bump **both** `MARKETING_VERSION` (e.g. `1.0.2`) and `CURRENT_PROJECT_VERSION`
   (monotonic build number, e.g. `3`) in `project.yml`. Sparkle compares the
   build number to decide "newer".
2. `export SPARKLE_PRIVATE_KEY=...` (or use Keychain).
3. Run `./scripts/package.sh <version>`.
4. Create GitHub Release `v<version>`, upload the DMG.
5. Paste the printed `<item>` into `docs/appcast.xml` and push to `main`.
6. GitHub Pages serves the updated feed; installed apps (≥ v1.0.2) auto-update.

## Data Flow (steady state, ≥ v1.0.2)

```
installed app --(SUFeedURL, periodic)--> docs/appcast.xml on GitHub Pages
  └─ finds newer <item> by sparkle:version
     └─ downloads DMG enclosure from GitHub Release
        └─ verifies sparkle:edSignature against embedded SUPublicEDKey
           └─ mounts DMG, swaps app in place, clears quarantine, relaunches
```

## Error / Edge Handling

- **Signature mismatch / missing key:** Sparkle refuses the update (fail-closed).
  Test by intentionally corrupting the signature once.
- **Non-monotonic build number:** update not offered. Checklist step 1 guards it.
- **Pages cache lag:** the feed may take a minute to propagate after push.
- **First-launch Gatekeeper:** v1.0.2 manual install needs right-click → Open
  once; documented for users.
- **Private key handling:** never in repo, never in script literals, never echoed.

## Testing / Verification

1. Build v1.0.2 with keys embedded; confirm `Info.plist` contains `SUFeedURL` +
   `SUPublicEDKey` (`PlistBuddy`/`codesign -dvv`).
2. Locally host a test appcast pointing at a v1.0.3 DMG; install v1.0.2; confirm
   "Check for Updates" detects, downloads, verifies, installs, relaunches as
   v1.0.3 **without reinstalling**.
3. Negative test: bad signature → update rejected.

## Out of Scope (YAGNI)

- CI / GitHub Actions release automation.
- Apple Developer ID code signing & notarization.
- Silent fully-automatic install (`automaticallyDownloadsUpdates`); keep the
  current check-and-prompt behavior unless requested later.
- Delta/binary-diff updates.
