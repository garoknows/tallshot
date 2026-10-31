#!/bin/bash
# Renders App/Resources/AppIcon.icns and the pictures in docs/images from the app's SwiftUI views.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="${TALLSHOT_BUILD_DIR:-$HOME/Library/Caches/Tallshot-build}/render"
mkdir -p "$B"
DEV="$(xcode-select -p)"
TC="$DEV/Toolchains/XcodeDefault.xctoolchain"
SWIFTC="$TC/usr/bin/swiftc"; [ -x "$SWIFTC" ] || SWIFTC=swiftc
SDK="$DEV/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
COMMON=(-swift-version 6 -sdk "$SDK" -module-cache-path "$B/modcache" -target "$(uname -m)-apple-macos14.0"
        -plugin-path "$DEV/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins" -plugin-path "$TC/usr/lib/swift/host/plugins")
"$SWIFTC" "${COMMON[@]}" -parse-as-library -emit-library -static -emit-module -module-name TallshotCore \
  -emit-module-path "$B/TallshotCore.swiftmodule" "$ROOT"/Packages/TallshotCore/Sources/TallshotCore/*.swift -o "$B/libTallshotCore.a"
SOURCES=$(ls "$ROOT"/App/Sources/*.swift | grep -v TallshotApp.swift)
# shellcheck disable=SC2086
"$SWIFTC" "${COMMON[@]}" -parse-as-library -I "$B" -L "$B" -lTallshotCore -module-name DocRenderer \
  $SOURCES "$ROOT/tools/DocRenderer/main.swift" -o "$B/DocRenderer"
rm -rf "$B/AppIcon.iconset"
mkdir -p "$ROOT/docs/images" "$ROOT/App/Resources"
"$B/DocRenderer" "$B/AppIcon.iconset" "$ROOT/docs/images"
iconutil -c icns "$B/AppIcon.iconset" -o "$ROOT/App/Resources/AppIcon.icns" 2>/dev/null \
  || python3 "$ROOT/tools/make-icns.py" "$B/AppIcon.iconset" "$ROOT/App/Resources/AppIcon.icns"
echo "Wrote App/Resources/AppIcon.icns"
