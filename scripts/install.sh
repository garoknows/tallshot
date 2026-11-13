#!/bin/bash
# Builds Tallshot from source, copies it to Applications and opens it.
# Apps you build yourself don't need the Gatekeeper "Open Anyway" step.
# Usage: scripts/install.sh                         (installs to ~/Applications)
#        TALLSHOT_DEST=/Applications scripts/install.sh
#        scripts/install.sh --remove-other-copies   (also deletes every other Tallshot.app that
#                                                    Spotlight can find, so only one remains)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Tallshot"
DEST="${TALLSHOT_DEST:-$HOME/Applications}"
BUNDLE_ID="io.github.garoknows.tallshot"
REMOVE_OTHERS=0
[ "${1:-}" = "--remove-other-copies" ] && REMOVE_OTHERS=1
fail() { printf '\n\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" != *"Xcode"*".app"* ]]; then
  fail "Full Xcode is required (the Command Line Tools alone can't build apps).
  1. Install Xcode from the Mac App Store (free).
  2. Open it once and let it finish setting up.
  3. Run: sudo xcode-select -s /Applications/Xcode.app
  Then run this script again."
fi

# If signing is set up, make sure the certificate is usable before spending time on a build.
scripts/signing-identity.sh >/dev/null || exit 1
TEAM="$(scripts/signing-team.sh)" || exit 1

# An ad hoc build must never replace a signed Tallshot in /Applications: macOS would treat it as
# a different app and its Screen Recording and Accessibility permissions would stop matching.
# That happens in a git worktree, which doesn't get the gitignored Config/Signing.xcconfig.
# (TALLSHOT_SIGNED_ONLY_DEST changes the folder, for scripts/test-signing-check.sh.)
SIGNED_ONLY="${TALLSHOT_SIGNED_ONLY_DEST:-/Applications}"
real_dir() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "${1%/}"; }
if [ -z "$TEAM" ] && [ "$(real_dir "$DEST")" = "$(real_dir "$SIGNED_ONLY")" ]; then
  MAIN="$(scripts/main-checkout.sh)"
  HERE="$(pwd -P)"
  if [ -n "$MAIN" ] && [ "$MAIN" != "$HERE" ] && [ -f "$MAIN/Config/Signing.xcconfig" ]; then
    fail "This copy of the code has no Config/Signing.xcconfig, so the build would be ad hoc signed.
  Installed in $SIGNED_ONLY, it would replace your signed Tallshot, and macOS would ask for
  Screen Recording and Accessibility again. Nothing was built or installed.
  The main checkout has the file. Copy it here, then run this again:
    cp \"$MAIN/Config/Signing.xcconfig\" \"$HERE/Config/\"
  (New worktrees made with scripts/new-worktree.sh get it automatically.)"
  fi
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

# Check the new build before touching the running or installed copy, so a refused build leaves
# everything as it was.
if [ -n "$TEAM" ]; then
  scripts/verify-signed.sh "$BUILT" || fail "The build isn't signed with your Developer ID. Nothing was installed, and the Tallshot you had is untouched."
  echo "macOS keeps Tallshot's permissions across rebuilds."
else
  echo "Ad hoc signed: macOS will ask for the permissions again after every rebuild (see Config/Signing.xcconfig.example)."
fi

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "Quitting the running copy…"
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in $(seq 1 20); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.25; done
fi

mkdir -p "$DEST"
# The plain full path (no trailing slash, no symlinks), as Spotlight reports it, so
# --remove-other-copies can recognize the copy installed here.
DEST="$(cd "$DEST" && pwd -P)"
rm -rf "$DEST/$APP_NAME.app"
ditto "$BUILT" "$DEST/$APP_NAME.app" || fail "Couldn't copy into $DEST."
# The build folder's copy would otherwise be a second Tallshot that macOS can find.
rm -rf "$BUILT"

if [ "$REMOVE_OTHERS" = 1 ]; then
  while IFS= read -r other; do
    [ -n "$other" ] && [ "$other" != "$DEST/$APP_NAME.app" ] || continue
    case "$other" in /Volumes/*) echo "Not removing $other: it's on a mounted disk image or drive. Eject it."; continue ;; esac
    [ "$(plutil -extract CFBundleIdentifier raw "$other/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] || continue
    rm -rf "$other" && echo "Removed $other" || echo "Couldn't remove $other. Delete it in Finder."
  done < <(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'")
fi

echo "Installed to $DEST/$APP_NAME.app. Opening it…"
open "$DEST/$APP_NAME.app" || fail "Installed, but macOS wouldn't open it yet. Double-click $APP_NAME in $DEST."
echo "Done. Look for the tall rounded icon in your menu bar."
