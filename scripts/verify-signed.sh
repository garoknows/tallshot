#!/bin/bash
# Usage: scripts/verify-signed.sh path/to/Tallshot.app
# When signing is set up (Config/Signing.xcconfig), succeeds only if the app is validly signed with
# a Developer ID Application certificate from that team. Anything else, ad hoc included, fails.
# Saves codesign's whole output before reading it. Piping it into `grep -q` is a race: grep quits
# at its match, codesign is killed while still writing, and pipefail reports that as a failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"
TEAM="$("$ROOT/scripts/signing-team.sh")"
if [ -z "$TEAM" ]; then echo "Signing isn't set up (no Config/Signing.xcconfig)."; exit 0; fi
if ! INFO="$(codesign -dv "$APP" 2>&1)"; then
  echo "Error: couldn't read the signature of $APP: $INFO" >&2; exit 1
fi
FOUND=""
while IFS= read -r line; do
  case "$line" in TeamIdentifier=*) FOUND="${line#TeamIdentifier=}" ;; esac
done <<< "$INFO"
if [ "$FOUND" != "$TEAM" ]; then
  echo "Error: signed by team '${FOUND:-none}', but Config/Signing.xcconfig says '$TEAM'." >&2; exit 1
fi
# The signature's own requirement, the identity macOS keeps permissions against. 100.6.1.13 marks a
# Developer ID Application certificate; subject.OU is its team. An ad hoc build has neither.
if ! REQ="$(codesign -d -r- "$APP" 2>&1)"; then
  echo "Error: couldn't read the signing requirement of $APP: $REQ" >&2; exit 1
fi
case "$REQ" in *"100.6.1.13"*) ;; *)
  echo "Error: right team, but not a Developer ID Application certificate." >&2; exit 1 ;;
esac
case "$REQ" in *"subject.OU] = $TEAM"*|*"subject.OU] = \"$TEAM\""*) ;; *)
  echo "Error: the signing requirement doesn't name team '$TEAM'." >&2; exit 1 ;;
esac
echo "Signed with your Developer ID."
