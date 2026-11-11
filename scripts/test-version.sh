#!/bin/bash
# Checks that the version line at the bottom of Settings matches the build: the built app's own
# Settings code must show "Tallshot <CFBundleShortVersionString>", and that must be project.yml's version.
# (The menu has no version line since 1.1.3.)
#   scripts/test-version.sh path/to/Tallshot.app
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: scripts/test-version.sh path/to/Tallshot.app}"
BIN="$APP/Contents/MacOS/Tallshot"
FAIL=0
# A build that doesn't know the flag would start the whole app: stop it after 10 seconds (a failure).
run() { perl -e 'alarm 10; exec @ARGV' "$BIN" "$@"; }
PLIST=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
YML=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$ROOT/project.yml")
echo "Info.plist says $PLIST, project.yml says $YML"
[ "$PLIST" = "$YML" ] && echo "  ok   the build has project.yml's version" || { echo "  FAIL the build's version isn't project.yml's"; FAIL=1; }
if run --settings-version-is "Tallshot $PLIST"; then echo "  ok   Settings shows \"Tallshot $PLIST\""
else echo "  FAIL Settings doesn't show \"Tallshot $PLIST\""; FAIL=1; fi
# The check must be able to fail: a wrong version is refused.
if run --settings-version-is "Tallshot 0.0.0-not-this"; then echo "  FAIL the check accepted a wrong version"; FAIL=1
else echo "  ok   a wrong version is refused"; fi
[ $FAIL = 0 ] && echo "Version checks passed." || echo "Version checks FAILED."
exit $FAIL
