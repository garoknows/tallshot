#!/bin/bash
# Prints the identity to sign local builds with: the Developer ID Application certificate for the
# team in Config/Signing.xcconfig (gitignored), or "-" (ad hoc) if there's no such file.
# Stops with an error if the file is there but the certificate can't be used, so a build never
# quietly turns ad hoc, which macOS would treat as a different app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/Config/Signing.xcconfig"
if [ ! -f "$CONFIG" ]; then echo "-"; exit 0; fi
TEAM="$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$CONFIG")"
IDENTITY="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | grep "($TEAM)" | awk 'NR==1 {print $2}' || true)"
if [ -z "$IDENTITY" ]; then
  echo "Error: no usable Developer ID Application certificate for the team in Config/Signing.xcconfig." >&2
  echo "Check with: security find-identity -v -p codesigning" >&2
  exit 1
fi
echo "$IDENTITY"
