#!/bin/bash
# Builds and runs the TallshotCore tests with swiftc directly (no SwiftPM or Xcode build system).
# For restricted environments where those tools can't write their temp files.
# Normal use: `swift test --package-path Packages/TallshotCore`.
#   run-tests-direct.sh            # engine tests + offscreen harness
#   run-tests-direct.sh core       # engine tests only
#   run-tests-direct.sh harness    # offscreen harness only
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WHICH="${1:-all}"; [ $# -gt 0 ] && shift
B="${TALLSHOT_BUILD_DIR:-$HOME/Library/Caches/Tallshot-build}/direct-tests"
mkdir -p "$B"
DEV="$(xcode-select -p)"
PLAT="$DEV/Platforms/MacOSX.platform/Developer"
TC="$DEV/Toolchains/XcodeDefault.xctoolchain"
SWIFTC="$TC/usr/bin/swiftc"; [ -x "$SWIFTC" ] || SWIFTC=swiftc
SDK="$PLAT/SDKs/MacOSX.sdk"
COMMON=(-swift-version 6 -O -sdk "$SDK" -module-cache-path "$B/modcache" -target "$(uname -m)-apple-macos14.0"
        -F "$PLAT/Library/Frameworks" -I "$PLAT/usr/lib" -L "$PLAT/usr/lib" -plugin-path "$TC/usr/lib/swift/host/plugins/testing")
"$SWIFTC" "${COMMON[@]}" -parse-as-library -enable-testing -emit-library -static -emit-module -module-name TallshotCore \
  -emit-module-path "$B/TallshotCore.swiftmodule" "$HERE"/Sources/TallshotCore/*.swift -o "$B/libTallshotCore.a"
cat > "$B/runner.swift" <<'SWIFT'
import Foundation
import Testing
@main struct Runner { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }
SWIFT
STATUS=0
for T in TallshotCoreTests TallshotHarnessTests; do
  [ "$WHICH" = core ] && [ $T = TallshotHarnessTests ] && continue
  [ "$WHICH" = harness ] && [ $T = TallshotCoreTests ] && continue
  ls "$HERE"/Tests/$T/*.swift >/dev/null 2>&1 || continue
  "$SWIFTC" "${COMMON[@]}" -parse-as-library -I "$B" -L "$B" -lTallshotCore -module-name $T \
    -Xlinker -rpath -Xlinker "$PLAT/Library/Frameworks" -Xlinker -rpath -Xlinker "$PLAT/usr/lib" \
    "$HERE"/Tests/$T/*.swift "$B/runner.swift" -o "$B/$T"
  echo "== $T"
  "$B/$T" "$@" || STATUS=1
done
exit $STATUS
