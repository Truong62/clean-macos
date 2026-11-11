#!/bin/bash
set -euo pipefail

APP="${1:?Usage: ./scripts/inject-auth.sh <path to MacKit.app>}"
ENV_FILE="${CLEAN_MACOS_AUTH_ENV:-$HOME/.config/clean-macos/google-auth.env}"
PLIST="$APP/Contents/Info.plist"

if [ ! -f "$ENV_FILE" ]; then
  echo "==> No $ENV_FILE: Google sign-in stays off in this build."
  exit 0
fi

source "$ENV_FILE"
for pair in "CMFirebaseAPIKey:${CM_FIREBASE_API_KEY:-}" "CMGoogleClientID:${CM_GOOGLE_CLIENT_ID:-}" "CMGoogleClientSecret:${CM_GOOGLE_CLIENT_SECRET:-}"; do
  key="${pair%%:*}"
  value="${pair#*:}"
  [ -n "$value" ] || { echo "ERROR: $key is empty in $ENV_FILE"; exit 1; }
  plutil -replace "$key" -string "$value" "$PLIST"
done
SIGN_ID="${MACKIT_SIGN_IDENTITY:-MacKit Self Signed}"
security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 || SIGN_ID=-
codesign --force --deep --sign "$SIGN_ID" "$APP"
echo "==> Google sign-in keys added to $APP"
