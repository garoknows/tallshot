#!/bin/bash
# Prints the Team ID in Config/Signing.xcconfig, or nothing if that file doesn't exist.
# Ignores comments, spaces, tabs and Windows line endings. If the file exists but holds no valid
# Team ID it stops with an error: signing is set up, so it must never turn into an ad hoc build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${TALLSHOT_SIGNING_CONFIG:-$ROOT/Config/Signing.xcconfig}"
[ -f "$CONFIG" ] || exit 0
TEAM="$(awk '
  { sub(/\r$/, ""); sub(/\/\/.*/, "") }
  /^[ \t]*DEVELOPMENT_TEAM[ \t]*=/ { sub(/^[^=]*=/, ""); gsub(/[ \t]/, ""); team = $0 }
  END { print team }
' "$CONFIG")"
if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Error: $(basename "$CONFIG") has no valid DEVELOPMENT_TEAM (10 capital letters and digits)." >&2
  exit 1
fi
echo "$TEAM"
