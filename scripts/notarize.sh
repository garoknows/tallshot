#!/usr/bin/env bash
# Notarize a file with Apple, retrying uploads that stall, then staple it.
# Usage: scripts/notarize.sh <file.zip|file.dmg> [file to staple]
# Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file) in the environment.
set -euo pipefail

FILE="$1"
STAPLE="${2:-$1}"
AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")

# macOS has no `timeout` command; perl's alarm does the same job.
with_timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }

ID=""
for attempt in 1 2 3; do
  echo "Uploading $FILE to Apple (attempt $attempt)…"
  if OUT=$(with_timeout 600 xcrun notarytool submit "$FILE" "${AUTH[@]}" --output-format json); then
    ID=$(plutil -extract id raw - <<<"$OUT" 2>/dev/null || true)
    [ -n "$ID" ] && break
  fi
  echo "Upload didn't finish; retrying in 30 seconds."
  sleep 30
done
[ -n "$ID" ] || { echo "Couldn't upload $FILE to Apple after 3 attempts."; exit 1; }
echo "Submission ID: $ID"

# Apple's processing can be slow; waiting is safe to repeat.
xcrun notarytool wait "$ID" "${AUTH[@]}" --timeout 45m || true
STATUS=$(xcrun notarytool info "$ID" "${AUTH[@]}" --output-format json | plutil -extract status raw -)
echo "Apple's verdict: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
  xcrun notarytool log "$ID" "${AUTH[@]}" || true
  exit 1
fi

xcrun stapler staple "$STAPLE"
xcrun stapler validate "$STAPLE"
