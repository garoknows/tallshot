#!/bin/bash
# Rules about the pointer and text capture that unit tests can't see in the app code.
#   1. A real "mouse moved" event is made in one place only (LiveDriver.movePointer), and that is
#      used only to restore the pointer after the last picture, never while pictures are taken.
#      (1.1.0 and 1.1.1 also used it to park the pointer, and the self-test failed.)
#   2. A text capture (SharedTextReader) only reads: it never scrolls, moves the pointer, posts
#      events or changes anything in the app.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/App/Sources"
FAIL=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }

MAKERS=$(grep -rn 'CGEvent(mouseEventSource' "$SRC")
if [ "$(grep -c . <<< "$MAKERS")" = 1 ] && grep -q 'LiveCapture.swift' <<< "$MAKERS" && \
   awk '/static func movePointer/{f=1} f&&/CGEvent\(mouseEventSource/{print "in"; exit} f&&/^    }/{exit}' "$SRC/LiveCapture.swift" | grep -q in; then
  pass "Real mouse events are made only in LiveDriver.movePointer"
else bad "Mouse events made outside LiveDriver.movePointer:"; echo "$MAKERS"; fi

USES=$(grep -rn 'movePointer' "$SRC" | grep -v 'static func movePointer' | grep -v '^\S*:\s*///')
OK1=$(grep -c 'PointerParking(jump: LiveDriver.jumpPointer, move: LiveDriver.movePointer' <<< "$USES")
OK2=$(grep -c 'sendMouseMove: { LiveDriver.movePointer' <<< "$USES")
if [ "$(grep -c . <<< "$USES")" = 2 ] && [ "$OK1" = 1 ] && [ "$OK2" = 1 ]; then
  pass "movePointer is used only by the restore (PointerParking's move) and the after-capture reset"
else bad "movePointer used elsewhere:"; echo "$USES"; fi

if grep -q 'pointer.park(at: target.scrollPoint)' "$SRC/LiveCapture.swift" && \
   ! grep -rn 'CGWarpMouseCursorPosition' "$SRC" | grep -v -E 'LiveCapture.swift:.*CGWarpMouseCursorPosition\(p\)' | grep -q .; then
  pass "Parking only jumps silently (CGWarpMouseCursorPosition only inside jumpPointer and movePointer)"
else bad "The pointer is moved some other way"; fi

FORBIDDEN='ScrollPoster|ScrollBarMover|CGEvent|CGWarp|AXUIElementSetAttributeValue|AXUIElementPerformAction|scroll\(|setValue'
if grep -n -E "$FORBIDDEN" "$SRC/SharedTextReader.swift" | grep -v '^\S*:\s*///' | grep -v -E '^\S*:\s*//' | grep -q .; then
  bad "Text capture does more than read:"; grep -n -E "$FORBIDDEN" "$SRC/SharedTextReader.swift"
else pass "Text capture only reads (no scrolling, events, pointer moves or changes)"; fi

[ $FAIL = 0 ] && echo "Capture rules hold." || echo "Capture rules FAILED."
exit $FAIL
