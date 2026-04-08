#!/bin/bash
set -euo pipefail

# ============================================================
# Clean macOS - Release Script
#
# Usage:
#   ./scripts/release.sh 1.2.0
#
# Prerequisites:
#   1. Generate EdDSA key pair (one-time):
#      ./scripts/generate-keys.sh
#
#   2. Set environment variable:
#      export SPARKLE_PRIVATE_KEY="your-private-key"
#
# What this script does:
#   1. Build release .app
#   2. Create .zip for distribution
#   3. Sign with Sparkle EdDSA key
#   4. Generate appcast.xml entry
#   5. Output ready for GitHub Release upload
# ============================================================

VERSION="${1:?Usage: ./scripts/release.sh <version> (e.g. 1.2.0)}"
APP_NAME="CleanMacOS"
BUILD_DIR=".build/release-output"
ZIP_NAME="${APP_NAME}-${VERSION}.zip"

# GitHub repo info - update this to your repo
GITHUB_REPO="sarus/clean-macos"
DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${ZIP_NAME}"

echo "==> Building ${APP_NAME} v${VERSION}..."

# Clean & build release
swift build -c release 2>&1

echo "==> Creating app bundle..."

# Create output directory
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/${APP_NAME}.app/Contents/MacOS"
mkdir -p "${BUILD_DIR}/${APP_NAME}.app/Contents/Resources"
mkdir -p "${BUILD_DIR}/${APP_NAME}.app/Contents/Frameworks"

# Copy binary
cp ".build/release/${APP_NAME}" "${BUILD_DIR}/${APP_NAME}.app/Contents/MacOS/"

# Copy Sparkle framework
SPARKLE_PATH=$(find .build -name "Sparkle.framework" -type d | head -1)
if [ -n "$SPARKLE_PATH" ]; then
    cp -R "$SPARKLE_PATH" "${BUILD_DIR}/${APP_NAME}.app/Contents/Frameworks/"
    echo "   Sparkle.framework copied"
fi

# Create Info.plist
cat > "${BUILD_DIR}/${APP_NAME}.app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Clean macOS</string>
    <key>CFBundleIdentifier</key>
    <string>com.sarus.CleanMacOS</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>SUFeedURL</key>
    <string>https://sarus.github.io/clean-macos/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>REPLACE_WITH_YOUR_PUBLIC_KEY</string>
</dict>
</plist>
PLIST

echo "==> Creating ${ZIP_NAME}..."

# Create zip
cd "${BUILD_DIR}"
ditto -c -k --keepParent "${APP_NAME}.app" "${ZIP_NAME}"
cd - > /dev/null

ZIP_PATH="${BUILD_DIR}/${ZIP_NAME}"
ZIP_SIZE=$(stat -f%z "${ZIP_PATH}")

echo "==> Signing update..."

# Sign with Sparkle EdDSA (if key is available)
SIGNATURE=""
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    SIGN_TOOL=$(find .build -name "sign_update" -type f | head -1)
    if [ -n "$SIGN_TOOL" ]; then
        SIGNATURE=$("$SIGN_TOOL" "${ZIP_PATH}" --ed-key-file <(echo "$SPARKLE_PRIVATE_KEY") 2>/dev/null || echo "")
    fi
fi

if [ -z "$SIGNATURE" ]; then
    echo "   ⚠ No signature generated. Set SPARKLE_PRIVATE_KEY or sign manually later."
    SIGNATURE="REPLACE_WITH_SIGNATURE"
fi

echo "==> Generating appcast entry..."

# Generate appcast entry
PUBDATE=$(date -R)
cat > "${BUILD_DIR}/appcast-entry.xml" << XML
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <description><![CDATA[
        <h2>What's New in ${VERSION}</h2>
        <ul>
          <li>TODO: Add release notes here</li>
        </ul>
      ]]></description>
      <enclosure
        url="${DOWNLOAD_URL}"
        length="${ZIP_SIZE}"
        type="application/octet-stream"
        sparkle:edSignature="${SIGNATURE}" />
    </item>
XML

echo ""
echo "============================================"
echo "  Release v${VERSION} ready!"
echo "============================================"
echo ""
echo "  App:     ${BUILD_DIR}/${APP_NAME}.app"
echo "  Zip:     ${ZIP_PATH} (${ZIP_SIZE} bytes)"
echo ""
echo "  Next steps:"
echo "  1. Edit release notes in ${BUILD_DIR}/appcast-entry.xml"
echo "  2. Copy the <item> block into appcast.xml"
echo "  3. Upload ${ZIP_NAME} to GitHub Release v${VERSION}"
echo "  4. Push appcast.xml to main branch"
echo ""
