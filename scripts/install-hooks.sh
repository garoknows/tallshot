#!/bin/sh
# Turns on the gitleaks pre-commit hook for this clone (hooks live in scripts/hooks).
git -C "$(dirname "$0")/.." config core.hooksPath scripts/hooks
echo "Pre-commit secret scan enabled (gitleaks protect --staged)."
