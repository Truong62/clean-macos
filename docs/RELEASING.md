# Releasing Clean macOS

Auto-update works for **v1.0.2 and later**. The already-shipped **v1.0.1 has no
feed URL and no public key**, so it cannot update itself.

## One-time migration for existing users (v1.0.1 → v1.0.2)

Each person already running v1.0.1 must install **v1.0.2 by hand, once**:

1. Download `CleanMacOS-1.0.2.dmg` from the GitHub release.
2. Open the DMG, drag **CleanMacOS.app** onto **Applications** (it replaces the
   old one — same name and bundle id, so no duplicate).
3. First launch only: **right-click the app → Open** to clear Gatekeeper
   (the app is ad-hoc signed, not notarized).

After this one manual install, every later version updates **in place**
automatically — no more reinstalls.

## One-time developer setup

- EdDSA signing key lives in your login **Keychain**
  (`./scripts/generate-keys.sh`). The matching `SUPublicEDKey` is embedded in
  `project.yml` → `info.properties`.
- **Back up the private key** (`generate_keys -x …`) in a password manager. If
  this Mac/Keychain is lost without the backup, you can never sign updates
  again and auto-update breaks permanently.
- `scripts/package.sh` reads the private key from the Keychain automatically;
  you never pass it on the command line.

## Each release

> ⚠️ **A GitHub Release alone does not trigger updates.** Sparkle reads the
> appcast feed (`docs/appcast.xml`), not the Releases page. Steps 3 and 5 (update
> the feed) are not optional — skip them and installed apps keep reporting "up to
> date" even though the DMG is published.

1. **Bump the version** in `CleanMacOS/project.yml`:
   - `MARKETING_VERSION` — the user-facing version, e.g. `1.0.3`.
   - `CURRENT_PROJECT_VERSION` — a **monotonically increasing** build number,
     e.g. `4`. Sparkle compares this (`sparkle:version`) to decide "newer", so it
     must go up every release.
2. **Build + sign:**
   ```bash
   cd CleanMacOS
   ./scripts/package.sh 1.0.3
   ```
   This produces `dist/CleanMacOS-1.0.3.dmg` and prints an `<item>` block with a
   real `sparkle:edSignature` and `length`.
3. **Edit the release notes** inside the printed `<item>`, then paste it at the
   **top** of the item list in `docs/appcast.xml` (newest first).
4. **Publish the DMG:**
   ```bash
   gh release create v1.0.3 CleanMacOS/dist/CleanMacOS-1.0.3.dmg --title "v1.0.3"
   ```
   (or upload the DMG via the GitHub Releases web UI). The download URL must
   match the `url` in the appcast item:
   `https://github.com/Truong62/clean-macos/releases/download/v1.0.3/CleanMacOS-1.0.3.dmg`
5. **Push the feed:**
   ```bash
   git add CleanMacOS/project.yml docs/appcast.xml && git commit -m "release v1.0.3" && git push
   ```
   GitHub Pages serves the updated `docs/appcast.xml`; installed apps pick it up
   on their next check.

## Verifying a build before publishing (optional)

The signature is verified cryptographically by Sparkle at update time against the
embedded `SUPublicEDKey`. To prove a fresh DMG will be accepted:

```bash
cd CleanMacOS
# 1) signing key matches the key embedded in the app:
diff <(.build/artifacts/sparkle/Sparkle/bin/generate_keys -p) \
     <(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Info.plist) && echo "key OK"
# 2) appcast length matches the DMG, signature matches sign_update output.
```

To watch a real in-place update end-to-end: install the current version to
`/Applications`, serve a local appcast pointing at a newer-numbered DMG over
`python3 -m http.server`, temporarily
`defaults write click.ngoctruong.CleanMacOS SUFeedURL http://localhost:8000/appcast-local.xml`,
then use Settings → Updates → "Check for Updates Now". Clean up with
`defaults delete click.ngoctruong.CleanMacOS SUFeedURL`.

## Gotchas

- **Always bump `CURRENT_PROJECT_VERSION`.** If it doesn't increase, no update is
  offered even if `MARKETING_VERSION` changed.
- **The served feed is `docs/appcast.xml`** (GitHub Pages = `main` `/docs`). There
  is no root `appcast.xml`.
- **Don't commit the DMG** — `CleanMacOS/dist/` is git-ignored; it goes to the
  GitHub Release only.
