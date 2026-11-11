#!/bin/bash
# Makes a git worktree and copies the main checkout's Config/Signing.xcconfig into it. That file
# is gitignored, so a plain `git worktree add` leaves it out, the build there is ad hoc signed,
# and macOS treats the installed app as a different one (its permissions stop matching).
#   scripts/new-worktree.sh <branch> [start-point]
# An existing branch is checked out; a new one starts at start-point (default origin/main).
# The worktree goes in ~/Library/Caches/Tallshot-build/worktrees/<branch, with / as ->
# (TALLSHOT_WORKTREES changes the parent folder).
set -euo pipefail
cd "$(dirname "$0")/.."
BRANCH="${1:?usage: scripts/new-worktree.sh <branch> [start-point]}"
START="${2:-origin/main}"
DIR="${TALLSHOT_WORKTREES:-$HOME/Library/Caches/Tallshot-build/worktrees}/${BRANCH//\//-}"
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git worktree add "$DIR" "$BRANCH"
else
  git worktree add --no-track -b "$BRANCH" "$DIR" "$START"
fi
MAIN="$(scripts/main-checkout.sh)"
if [ -n "$MAIN" ] && [ -f "$MAIN/Config/Signing.xcconfig" ]; then
  cp "$MAIN/Config/Signing.xcconfig" "$DIR/Config/Signing.xcconfig"
  echo "Copied Config/Signing.xcconfig from $MAIN: builds here are signed with your Developer ID."
else
  echo "The main checkout has no Config/Signing.xcconfig: builds here are ad hoc signed, as there."
fi
echo "Worktree ready: $DIR"
