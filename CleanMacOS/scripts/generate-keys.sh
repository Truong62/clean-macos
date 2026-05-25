#!/bin/bash
set -euo pipefail

# ============================================================
# Generate Sparkle EdDSA key pair (one-time setup)
#
# This creates a signing key for Sparkle auto-updates.
# - Private key: keep SECRET, use when signing releases
# - Public key: put in Info.plist (SUPublicEDKey)
# ============================================================

echo "==> Looking for Sparkle generate_keys tool..."

GENERATE_KEYS=$(find .build -name "generate_keys" -type f 2>/dev/null | head -1)

if [ -z "$GENERATE_KEYS" ]; then
    echo "   Building first to get Sparkle tools..."
    swift build 2>&1
    GENERATE_KEYS=$(find .build -name "generate_keys" -type f | head -1)
fi

if [ -z "$GENERATE_KEYS" ]; then
    echo "Error: Could not find generate_keys tool"
    exit 1
fi

echo "==> Generating EdDSA key pair..."
echo ""
"$GENERATE_KEYS"
echo ""
echo "============================================"
echo "  IMPORTANT:"
echo "============================================"
echo ""
echo "  1. Save the PRIVATE key somewhere safe (password manager)"
echo "     You need it every time you sign a release."
echo ""
echo "  2. Copy the PUBLIC key into:"
echo "     - project.yml → target info.properties → SUPublicEDKey"
echo "       (then run 'xcodegen generate' to regenerate Info.plist)"
echo ""
echo "  3. The PRIVATE key stays in your Keychain; scripts/package.sh reads it"
echo "     automatically when signing. Back it up with:"
echo "       <generate_keys> -x sparkle_private_key.txt   (store in a password manager)"
echo ""
