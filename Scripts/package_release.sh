#!/usr/bin/env bash
# Builds FortiBar.app and wraps it in a DMG for a GitHub release, then prints
# the sha256 the Homebrew cask needs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

"$ROOT_DIR/Scripts/build_app.sh"

DMG="$ROOT_DIR/dist/FortiBar.dmg"
rm -f "$DMG"

echo "Creating DMG…"
hdiutil create \
    -volname "FortiBar" \
    -srcfolder "$ROOT_DIR/dist/FortiBar.app" \
    -ov -format UDZO \
    "$DMG" >/dev/null

echo "Built: $DMG"
echo "sha256: $(shasum -a 256 "$DMG" | awk '{print $1}')"
