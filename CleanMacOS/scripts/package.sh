#!/bin/bash
set -euo pipefail

# ============================================================
# Clean macOS - Package & Sign for Sparkle auto-update
#
# Usage:   ./scripts/package.sh <version>      e.g. ./scripts/package.sh 1.0.2
#
# Prereq:  EdDSA signing key in the login Keychain (one-time):
#            ./scripts/generate-keys.sh
#          The public key must already be embedded in project.yml
#          (SUPublicEDKey) and the version bumped (MARKETING_VERSION +
#          CURRENT_PROJECT_VERSION).
#
# Produces: dist/CleanMacOS-<version>.dmg  (EdDSA-signed)
#           + prints the <item> block to paste into docs/appcast.xml.
# You still upload the DMG to the GitHub Release manually.
# ============================================================

VERSION="${1:?Usage: ./scripts/package.sh <version> (e.g. 1.0.2)}"
cd "$(dirname "$0")/.."

GITHUB_REPO="Truong62/clean-macos"
DIST="dist"
DMG="${DIST}/CleanMacOS-${VERSION}.dmg"
SIGN_TOOL=".build/artifacts/sparkle/Sparkle/bin/sign_update"

# xcodebuild needs full Xcode; fall back to /Applications/Xcode.app if the
# active developer dir is the Command Line Tools.
if ! xcode-select -p | grep -q "Xcode.app"; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

[ -x "$SIGN_TOOL" ] || { echo "ERROR: $SIGN_TOOL missing — run 'swift build' once."; exit 1; }

echo "==> Generating project & building Release..."
xcodegen generate
xcodebuild -project CleanMacOS.xcodeproj -scheme CleanMacOS \
  -configuration Release -derivedDataPath .build/dd build 2>&1 | tail -3
APP=$(find .build/dd/Build/Products/Release -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "ERROR: build produced no .app"; exit 1; }

echo "==> Verifying embedded version matches ${VERSION}..."
PLIST_V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILD_V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
[ "$PLIST_V" = "$VERSION" ] || {
  echo "ERROR: app version is $PLIST_V but you asked for $VERSION."
  echo "       Bump MARKETING_VERSION (and CURRENT_PROJECT_VERSION) in project.yml first."
  exit 1
}

echo "==> Building DMG..."
rm -rf "$DIST"; mkdir -p "$DIST"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Clean macOS ${VERSION}" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

SIZE=$(stat -f%z "$DMG")

echo "==> EdDSA-signing the DMG (private key read from Keychain)..."
# sign_update prints e.g.:  sparkle:edSignature="..." length="..."
SIG_LINE=$("$SIGN_TOOL" "$DMG")

PUBDATE=$(LC_TIME=C date "+%a, %d %b %Y %H:%M:%S %z")
DLURL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/CleanMacOS-${VERSION}.dmg"

cat <<XML

============================================================
  DMG ready: ${DMG} (${SIZE} bytes)
  Paste this <item> into docs/appcast.xml (newest item first):
============================================================

    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_V}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <description><![CDATA[
        <ul><li>TODO: release notes for ${VERSION}</li></ul>
      ]]></description>
      <enclosure
        url="${DLURL}"
        type="application/octet-stream"
        ${SIG_LINE} />
    </item>

  Next:
    1) edit the release notes above
    2) paste the <item> into docs/appcast.xml
    3) gh release create v${VERSION} "${DMG}"   (or upload the DMG via the web UI)
    4) commit & push docs/appcast.xml + project.yml to main
XML
