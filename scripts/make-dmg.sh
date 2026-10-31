#!/bin/bash
# Packages Tallshot.app into a .dmg with an Applications shortcut, using macOS's hdiutil.
# Usage: scripts/make-dmg.sh path/to/Tallshot.app path/to/Tallshot-0.1.0.dmg
set -euo pipefail
APP="$1"; OUT="$2"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/tallshot-dmg.XXXXXX")"
ditto "$APP" "$STAGE/Tallshot.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Tallshot" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"
echo "Wrote $OUT"
