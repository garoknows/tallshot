#!/bin/bash
# Builds Tallshot from source, copies it to Applications and opens it.
# Apps you build yourself don't need the Gatekeeper "Open Anyway" step.
# Usage: scripts/install.sh                         (installs to ~/Applications)
#        TALLSHOT_DEST=/Applications scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tallshot"
DEST="${TALLSHOT_DEST:-$HOME/Applications}"
fail() { printf '\n\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" != *"Xcode"*".app"* ]]; then
  fail "Full Xcode is required (the Command Line Tools alone can't build apps).
  1. Install Xcode from the Mac App Store (free).
  2. Open it once and let it finish setting up.
  3. Run: sudo xcode-select -s /Applications/Xcode.app
  Then run this script again."
fi

# Keep build output out of iCloud: Desktop/Documents syncing breaks code signing.
BUILD_DIR="${TALLSHOT_BUILD_DIR:-$HOME/Library/Caches/Tallshot-build}"
mkdir -p "$BUILD_DIR"
[ -e build.nosync ] || ln -s "$BUILD_DIR" build.nosync

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate --quiet
  echo "Building $APP_NAME (Release)… this takes a minute the first time."
  xcodebuild -project Tallshot.xcodeproj -scheme Tallshot -configuration Release \
    -derivedDataPath "$BUILD_DIR/dd" -destination "generic/platform=macOS" -quiet build \
    || fail "The build failed. Scroll up for the first error, or open an issue: https://github.com/garoknows/tallshot/issues"
  BUILT="$BUILD_DIR/dd/Build/Products/Release/$APP_NAME.app"
else
  echo "XcodeGen not found (brew install xcodegen); building with swiftc instead."
  scripts/build-direct.sh
  BUILT="$BUILD_DIR/direct-app/$APP_NAME.app"
fi
[ -d "$BUILT" ] || fail "Build finished but the app wasn't found at: $BUILT"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Quitting the running copy…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.25; done
fi

mkdir -p "$DEST"
rm -rf "$DEST/$APP_NAME.app"
ditto "$BUILT" "$DEST/$APP_NAME.app" || fail "Couldn't copy into $DEST."
echo "Installed to $DEST/$APP_NAME.app. Opening it…"
open "$DEST/$APP_NAME.app" || fail "Installed, but macOS wouldn't open it yet. Double-click $APP_NAME in $DEST."
echo "Done. Look for the tall rounded icon in your menu bar."
