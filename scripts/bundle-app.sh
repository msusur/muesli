#!/usr/bin/env bash
# Builds the menu-bar app and wraps it in Muesli.app.
#
# SwiftPM builds executables, not app bundles, and an app bundle is what gives
# Muesli its own permissions (instead of borrowing your terminal's), its own
# notifications and a login item.
#
# Usage: scripts/bundle-app.sh            → .build/Muesli.app
#        scripts/bundle-app.sh --install  → also copies it to ~/Applications and opens it
#
# Signing: set MUESLI_SIGN_IDENTITY to a code-signing identity (see
# `security find-identity -v -p codesigning`). Without one the app is signed
# ad hoc, and macOS treats every rebuild as a new app, so it asks for the
# microphone and system-audio permissions again after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MuesliApp
BIN="$(swift build -c release --show-bin-path)"

APP=.build/Muesli.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MuesliApp" "$APP/Contents/MacOS/MuesliApp"
cp Sources/MuesliApp/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

IDENTITY="${MUESLI_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier dev.muesli.app "$APP"
codesign --verify "$APP"
echo "built $APP (signed: ${MUESLI_SIGN_IDENTITY:-ad hoc})"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/Muesli.app"
  mkdir -p "$HOME/Applications"
  # Quit a running copy first, or the old binary keeps running.
  osascript -e 'tell application id "dev.muesli.app" to quit' >/dev/null 2>&1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "installed $DEST"
  open "$DEST"
fi
