#!/bin/bash
# Prints the main checkout's folder (where Config/Signing.xcconfig lives), also when run from a
# linked git worktree. Works whether the repo keeps its git data in .git or in a separate git
# folder whose core.worktree names the checkout (as the Tallshot repo's does). A separate git
# folder without core.worktree doesn't say where its checkout is: then, and outside git, this
# prints nothing.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0
COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
WT="$(git --git-dir="$COMMON" config --get core.worktree 2>/dev/null || true)"
if [ -n "$WT" ]; then
  case "$WT" in /*) ;; *) WT="$COMMON/$WT" ;; esac
  (cd "$WT" 2>/dev/null && pwd -P)
elif [ "$(basename "$COMMON")" = .git ]; then
  (cd "$(dirname "$COMMON")" && pwd -P)
fi
exit 0
