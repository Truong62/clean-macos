#!/bin/bash
set -euo pipefail

# ponytail: patches the KeyboardShortcuts checkout (CLT has no PreviewsMacros; SwiftPM's
# Bundle.module looks beside the .app, not in Resources). Drop once Xcode is installed.

cd "$(dirname "$0")/.."

APP=".build/spm-app/CleanMacOS.app"
KS=".build/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts"
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\(.*\)"/\1/p' project.yml)

swift package resolve
chmod -R u+w "$KS"
python3 - "$KS" <<'PY'
import re, sys
ks = sys.argv[1]
p = f"{ks}/Recorder.swift"
s = open(p).read()
open(p, "w").write(re.sub(r"#Preview \{.*?\n\}\n", "", s, flags=re.S))
p = f"{ks}/Utilities.swift"
s = open(p).read()
open(p, "w").write(s.replace(
    "bundle: .module,",
    'bundle: Bundle(url: Bundle.main.resourceURL!.appendingPathComponent("KeyboardShortcuts_KeyboardShortcuts.bundle")) ?? .main,'))
PY

swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/CleanMacOS" "$APP/Contents/MacOS/"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/CleanMacOS"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
ditto Sources/Resources/JiraWeb "$APP/Contents/Resources/JiraWeb"
ditto "$BIN/KeyboardShortcuts_KeyboardShortcuts.bundle" "$APP/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle"

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
cp Sources/Assets.xcassets/AppIcon.appiconset/*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' \
    -e 's/$(EXECUTABLE_NAME)/CleanMacOS/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/click.ngoctruong.CleanMacOS/' \
    -e "s/\$(MARKETING_VERSION)/$VERSION/" \
    -e "s/\$(CURRENT_PROJECT_VERSION)/$BUILD/" \
    Info.plist > "$APP/Contents/Info.plist"
plutil -insert CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
printf "APPL????" > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
