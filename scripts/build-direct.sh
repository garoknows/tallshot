#!/bin/bash
# Builds Tallshot.app with swiftc directly, without Xcode's build system.
# The normal way is `scripts/install.sh` (Xcode). This script is for environments where
# xcodebuild can't run, and it produces the same hardened-runtime, signed app.
#
# Usage: scripts/build-direct.sh [version]
# Env:   TALLSHOT_BUILD_DIR (default ~/Library/Caches/Tallshot-build)
#        SIGN_IDENTITY      (default "-" = ad hoc; e.g. "Developer ID Application")
#        TALLSHOT_SANDBOX=1 builds the App Sandbox experiment instead (never released)
#        ARCHS              (default "arm64 x86_64")
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
B="${TALLSHOT_BUILD_DIR:-$HOME/Library/Caches/Tallshot-build}/direct-app"
IDENTITY="${SIGN_IDENTITY:--}"
APP="$B/Tallshot.app"
DEV="$(xcode-select -p)"
TC="$DEV/Toolchains/XcodeDefault.xctoolchain"
SWIFTC="$TC/usr/bin/swiftc"; [ -x "$SWIFTC" ] || SWIFTC=swiftc
SDK="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
ENT="$ROOT/App/Tallshot.entitlements"
[ "${TALLSHOT_SANDBOX:-0}" = 1 ] && ENT="$ROOT/App/Tallshot-sandbox-experiment.entitlements"
mkdir -p "$B"

ARCHS="${ARCHS:-arm64 x86_64}"
BINS=()
for ARCH in $ARCHS; do
  O="$B/$ARCH"; mkdir -p "$O"
  # Load macro plugins in-process (-plugin-path) rather than through swift-plugin-server.
  COMMON=(-swift-version 6 -O -whole-module-optimization -sdk "$SDK" -target "$ARCH-apple-macos14.0" -module-cache-path "$B/modcache" -plugin-path "$DEV/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" -plugin-path "$TC/usr/lib/swift/host/plugins")
  "$SWIFTC" "${COMMON[@]}" -parse-as-library -emit-library -static -emit-module -module-name TallshotCore \
    -emit-module-path "$O/TallshotCore.swiftmodule" "$ROOT"/Packages/TallshotCore/Sources/TallshotCore/*.swift -o "$O/libTallshotCore.a"
  "$SWIFTC" "${COMMON[@]}" -parse-as-library -I "$O" -L "$O" -lTallshotCore -module-name Tallshot \
    "$ROOT"/App/Sources/*.swift -o "$O/Tallshot"
  BINS+=("$O/Tallshot")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
LIPO="$TC/usr/bin/lipo"; [ -x "$LIPO" ] || LIPO=lipo
"$LIPO" -create "${BINS[@]}" -output "$APP/Contents/MacOS/Tallshot"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "${BUILD_NUMBER:-1}" "$APP/Contents/Info.plist"
[ -f "$ROOT/App/Resources/AppIcon.icns" ] && cp "$ROOT/App/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

TS="--timestamp=none"; [ "$IDENTITY" != "-" ] && TS="--timestamp"
codesign --force --options runtime $TS --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
