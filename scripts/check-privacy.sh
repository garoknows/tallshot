#!/bin/bash
# Checks Tallshot's privacy rules in the source and, if given, in a built app.
#   scripts/check-privacy.sh                       # source checks
#   scripts/check-privacy.sh path/to/Tallshot.app  # source + built app checks
# Exit code 0 means every rule held.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"
FAIL=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
SRC=("$ROOT/App/Sources" "$ROOT/Packages/TallshotCore/Sources")

echo "Entitlements (App/Tallshot.entitlements)"
ENT="$ROOT/App/Tallshot.entitlements"
KEYS=$(plutil -convert json -o - "$ENT" 2>/dev/null)
[ "$KEYS" = "{}" ] && pass "No entitlements at all (no network, files, camera, microphone, contacts)" || bad "Entitlements present: $KEYS"

echo "Source code (app, engine and exports)"
NET='URLSession|NSURLConnection|URLRequest|import Network|CFSocket|NWConnection|NWPathMonitor|NWListener|WebSocket|socket\(|CFStream|NSStream|getaddrinfo|WKWebView|import WebKit'
if grep -rn -E "$NET" "${SRC[@]}" >/dev/null; then bad "Network code found:"; grep -rn -E "$NET" "${SRC[@]}"
else pass "No network code"; fi

# Below, text is checked with `grep -q ... <<< "$X"`, never `echo "$X" | grep -q`. With pipefail,
# grep quitting at its match can kill the writer, and that reads as "no match": a false pass.

# Tallshot writes files in exactly two places, both into the folder the user chose:
#  - ExportFiles.swift: the finished capture (PNG, and PDF / Word / Markdown if those are on),
#    written straight into the folder (no temp copy elsewhere, never overwriting).
#  - DiagnosticsReport.swift: a report folder next to the capture or in the folder chosen for
#    reports, only when the user turned on "Keep a diagnostic report" and a capture stopped early
#    (the app's DiagnosticsWriter calls it, guarded by that setting; checked below).
WRITES='\.write\(to|\.write\(toFile|FileManager\.default\.create|createFile|copyItem|\bmoveItem|replaceItem|linkItem|FileHandle|fopen|mkstemp|NSKeyedArchiver|CGImageDestinationCreateWithURL|CGPDFContextCreateWithURL|CGDataConsumer\(url'
OTHER=$(grep -rn -E "$WRITES" "${SRC[@]}" | grep -v 'Sources/TallshotExport/ExportFiles.swift:.*write(to: url, options: .withoutOverwriting)' | grep -v 'Sources/TallshotExport/DiagnosticsReport.swift:')
if [ -n "$OTHER" ]; then bad "File writes outside the export writer and the opt-in diagnostics:"; echo "$OTHER"
else pass "Only file writes: the capture's files, and the opt-in diagnostic report, both in the chosen folder"; fi
ATOMIC='\.atomic\b|atomically: *true'
if grep -rn -E "$ATOMIC" "${SRC[@]}" >/dev/null; then bad "Atomic writes stage a temp copy outside the chosen folder:"; grep -rn -E "$ATOMIC" "${SRC[@]}"
else pass "No atomic writes (nothing staged in a temp folder first)"; fi
DIAG=$(grep -B3 'DiagnosticsWriter.write' "$ROOT/App/Sources/AppModel.swift")
if grep -q 'DiagnosticsWriter.write' <<< "$DIAG" && \
   grep -q 'DiagnosticsWriter.shouldWrite(settingOn: settings.keepDiagnostics' <<< "$DIAG"; then
  pass "Diagnostic report written only when its setting is on (and it is off by default)"
else bad "DiagnosticsWriter.write is not guarded by the keepDiagnostics setting"; fi
REPORT=$(grep -rln 'DiagnosticsReport.write' "$ROOT/App/Sources")
[ "$REPORT" = "$ROOT/App/Sources/DiagnosticsWriter.swift" ] && pass "Diagnostic report written only through DiagnosticsWriter" \
  || bad "DiagnosticsReport.write called from somewhere other than DiagnosticsWriter: $REPORT"
grep -q 'Keys.diagnostics: false' "$ROOT/App/Sources/Settings.swift" && pass "Diagnostics setting defaults to off" || bad "Diagnostics setting is not off by default"
TEMP='NSTemporaryDirectory|temporaryDirectory|cachesDirectory|itemReplacementDirectory|applicationSupportDirectory|URLCache|"/tmp|"/var/'
if grep -rn -E "$TEMP" "${SRC[@]}" >/dev/null; then
  bad "Temp or cache folder use found:"; grep -rn -E "$TEMP" "${SRC[@]}"
else pass "No temp files or caches (frames stay in memory)"; fi
# Other programs could write or send anything, so only the two known ones may be started: a
# second copy of Tallshot that only reports the Screen Recording answer, and /bin/sh waiting to
# reopen Tallshot after it quits.
PROCS=$(grep -rn -E 'Process\(|posix_spawn|NSTask|(^|[^.A-Za-z])system\(' "${SRC[@]}")
PROCS_OK=$(grep -c -E 'AppModel.swift:[0-9]+: +let p = Process\(\)' <<< "$PROCS")
if [ -z "$PROCS" ] || { [ "$(grep -c . <<< "$PROCS")" = 2 ] && [ "$PROCS_OK" = 2 ] && \
     grep -q 'p.executableURL = exe' "$ROOT/App/Sources/AppModel.swift" && grep -q 'URL(fileURLWithPath: "/bin/sh")' "$ROOT/App/Sources/AppModel.swift"; }; then
  pass "Starts no other programs (only Tallshot itself, and the reopen helper)"
else bad "Starts other programs:"; echo "$PROCS"; fi
if grep -rn -E 'os_log|Logger\(|NSLog|print\(|debugPrint\(|dump\(' "${SRC[@]}" >/dev/null; then
  bad "Logging found:"; grep -rn -E 'os_log|Logger\(|NSLog|print\(|debugPrint\(|dump\(' "${SRC[@]}"
else pass "No logging"; fi
if grep -n -E '\.package\(' "$ROOT/Packages/TallshotCore/Package.swift" >/dev/null || grep -n -E '^\s+url:' "$ROOT/project.yml" >/dev/null; then
  bad "Third-party package dependency found"
else pass "No third-party packages"; fi
if grep -rn -i -E 'analytics|telemetry|crashlytics|sentry|sparkle|firebase|mixpanel' "${SRC[@]}" >/dev/null; then
  bad "Analytics, crash reporting or updater code found"
else pass "No analytics, crash reporting or auto-updater"; fi
SETS=$(grep -rn -E '\bd\.set\(|UserDefaults[^\n]*\.set\(' "${SRC[@]}" | grep -v -E 'forKey: (Keys\.|key\))')
[ -z "$SETS" ] && pass "UserDefaults holds only the settings keys" || { bad "UserDefaults stores something other than settings:"; echo "$SETS"; }
if grep -rn -E 'SCStream\(|startCapture' "${SRC[@]}" >/dev/null; then bad "Continuous screen stream found (captures must be one-shot screenshots)"
else pass "Screen read only with one-shot screenshots during a capture (no background stream)"; fi
if grep -rn -E 'Timer\.scheduledTimer|Timer\.publish' "${SRC[@]}" | grep -v SetupView.swift >/dev/null; then
  bad "Background timer found outside the setup window"
else pass "No background timers (only the setup window polls permissions while it is open)"; fi

if [ -n "$APP" ]; then
  echo "Built app ($APP)"
  E=$(codesign -d --entitlements :- "$APP" 2>/dev/null)
  grep -q "com.apple.security" <<< "$E" && bad "Signature carries entitlements: $(echo "$E" | grep -o 'com\.apple\.security[^<]*')" || pass "Signature carries no entitlements"
  SIG=$(codesign -dv "$APP" 2>&1); grep -q "flags=.*runtime" <<< "$SIG" && pass "Hardened runtime on" || bad "Hardened runtime off"
  BIN="$APP/Contents/MacOS/Tallshot"
  LIBS=$(otool -L "$BIN" 2>/dev/null | grep -v -E ':$' | awk '{print $1}' | grep -v -E '^/System/Library/|^/usr/lib/' || true)
  [ -z "$LIBS" ] && pass "Links only Apple system libraries" || bad "Non-system libraries: $LIBS"
  SYMS=$(nm -u "$BIN" 2>/dev/null)
  grep -q -E 'URLSession|NSURLConnection|_connect$|_socket$|nw_connection|CFSocket|getaddrinfo' <<< "$SYMS" && bad "Network symbols referenced" || pass "No network symbols referenced"
  grep -q -E 'NSTemporaryDirectory|_mkstemp|_tmpfile' <<< "$SYMS" && bad "Temp-file symbols referenced" || pass "No temp-file symbols referenced"
fi

[ $FAIL = 0 ] && echo "All privacy checks passed." || echo "Privacy checks FAILED."
exit $FAIL
