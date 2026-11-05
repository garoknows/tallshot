#!/bin/bash
# Tests signing-team.sh and verify-signed.sh with a stand-in codesign. No certificate needed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/tallshot-signing-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
FAIL=0
T=ABCDE12345
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=1; }

export TALLSHOT_SIGNING_CONFIG="$W/Signing.xcconfig"
team_is() { # name, wanted team, file contents
  printf "$3" > "$TALLSHOT_SIGNING_CONFIG"
  local got; got="$("$ROOT/scripts/signing-team.sh" 2>/dev/null)"
  [ "$got" = "$2" ] && ok "$1" || bad "$1: got '$got'"
}
echo "Reading the team"
team_is "plain"                "$T" "DEVELOPMENT_TEAM = $T\n"
team_is "no spaces"            "$T" "DEVELOPMENT_TEAM=$T\n"
team_is "trailing spaces"      "$T" "DEVELOPMENT_TEAM = $T   \n"
team_is "tabs"                 "$T" "\tDEVELOPMENT_TEAM\t=\t$T\t\n"
team_is "carriage return"      "$T" "DEVELOPMENT_TEAM = $T\r\n"
team_is "trailing comment"     "$T" "DEVELOPMENT_TEAM = $T // my team\n"
team_is "commented-out line"   "$T" "// DEVELOPMENT_TEAM = ZZZZZ99999\nDEVELOPMENT_TEAM = $T\n"
team_is "no newline at end"    "$T" "DEVELOPMENT_TEAM = $T"
team_is "last one wins"        "$T" "DEVELOPMENT_TEAM = ZZZZZ99999\nDEVELOPMENT_TEAM = $T\n"

refused() { # name, file contents
  printf "$2" > "$TALLSHOT_SIGNING_CONFIG"
  "$ROOT/scripts/signing-team.sh" >/dev/null 2>&1 && bad "$1 should stop" || ok "$1 stops"
}
refused "empty team"         "DEVELOPMENT_TEAM =\n"
refused "no team line"       "CODE_SIGN_STYLE = Manual\n"
refused "only commented out" "// DEVELOPMENT_TEAM = $T\n"
refused "malformed team"     "DEVELOPMENT_TEAM = abc\n"

# A stand-in codesign: prints FAKE_OUTPUT (-dv) or FAKE_REQ (-r-) line by line with a pause, which
# is what made the old `codesign | grep -q` check fail.
mkdir -p "$W/bin"
cat > "$W/bin/codesign" <<'FAKE'
#!/bin/bash
TEXT="$FAKE_OUTPUT"; [ "$2" = "-r-" ] && TEXT="$FAKE_REQ"
while IFS= read -r line; do echo "$line" >&2; sleep 0.02; done <<< "$TEXT"
exit "${FAKE_DISPLAY_EXIT:-0}"
FAKE
chmod +x "$W/bin/codesign"
GOOD="Identifier=io.github.garoknows.tallshot
Signature size=4666
TeamIdentifier=$T
Runtime Version=27.2.0
Sealed Resources version=2 rules=13 files=2
Internal requirements count=1 size=220"
req() { echo "designated => anchor apple generic and identifier \"io.github.garoknows.tallshot\" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = $1)"; }
export FAKE_REQ; FAKE_REQ="$(req "$T")"
printf 'DEVELOPMENT_TEAM = %s\n' "$T" > "$TALLSHOT_SIGNING_CONFIG"
verify() { PATH="$W/bin:$PATH" "$ROOT/scripts/verify-signed.sh" /fake.app >/dev/null 2>&1; }

echo "Checking the build"
pass=0; for _ in 1 2 3 4 5 6 7 8 9 10; do FAKE_OUTPUT="$GOOD" verify && pass=$((pass+1)); done
[ "$pass" = 10 ] && ok "right team, output continues after the match: passes every time" || bad "passed only $pass of 10"
FAKE_OUTPUT="$GOOD" FAKE_REQ="$(req "\"$T\"")" verify && ok "team in quotes in the requirement: passes" || bad "quoted team refused"
FAKE_OUTPUT="Signature=adhoc
TeamIdentifier=not set" FAKE_REQ="designated => cdhash H\"00\"" verify && bad "ad hoc accepted" || ok "ad hoc refused"
FAKE_OUTPUT="${GOOD//$T/ZZZZZ99999}" verify && bad "other team accepted" || ok "another team refused"
FAKE_OUTPUT="$GOOD" FAKE_REQ="designated => anchor apple generic and certificate leaf[subject.OU] = $T" verify && bad "development certificate accepted" || ok "right team, wrong kind of certificate refused"
FAKE_OUTPUT="$GOOD" FAKE_REQ="$(req ZZZZZ99999)" verify && bad "requirement for another team accepted" || ok "requirement naming another team refused"
FAKE_OUTPUT="Identifier=x" verify && bad "no team accepted" || ok "no team refused"
FAKE_OUTPUT="code object is not signed at all" FAKE_DISPLAY_EXIT=1 verify && bad "unsigned accepted" || ok "unsigned refused"

export TALLSHOT_SIGNING_CONFIG="$W/none.xcconfig"
PATH="$W/bin:$PATH" FAKE_OUTPUT="" "$ROOT/scripts/verify-signed.sh" /fake.app >/dev/null 2>&1 && ok "no config file: not an error" || bad "no config file should be fine"

[ $FAIL = 0 ] && echo "All signing check tests passed." || echo "Signing check tests FAILED."
exit $FAIL
