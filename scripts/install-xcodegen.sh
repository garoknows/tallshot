#!/bin/bash
# Downloads one exact XcodeGen release and checks its SHA-256 before using it, so CI never runs
# whatever version Homebrew happens to have that day. Prints the folder to add to PATH.
#   scripts/install-xcodegen.sh <folder>
set -euo pipefail
VERSION="2.46.0"
SHA256="4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806"
DIR="${1:?usage: install-xcodegen.sh <folder>}"
mkdir -p "$DIR"
curl -fsSL --retry 3 -o "$DIR/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/$VERSION/xcodegen.zip"
echo "$SHA256  $DIR/xcodegen.zip" | shasum -a 256 -c - >&2
unzip -q -o "$DIR/xcodegen.zip" -d "$DIR"
rm "$DIR/xcodegen.zip"
"$DIR/xcodegen/bin/xcodegen" --version >&2
echo "$DIR/xcodegen/bin"
