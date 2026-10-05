#!/bin/bash
# Build FortiBar.app into dist/ (app + privileged helper + helper installer).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release

APP="$ROOT/dist/FortiBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/FortiBar" "$APP/Contents/MacOS/FortiBar"
# Privileged helper + its installer; installed once into /Library by the app.
cp "$ROOT/.build/release/FortiBarHelper" "$APP/Contents/Resources/FortiBarHelper"
cp "$ROOT/Scripts/install-helper.sh" "$APP/Contents/Resources/install-helper.sh"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps keychain access (saved PSK/password) working
# across rebuilds; ad-hoc signatures change every build and trigger prompts.
# Override with CODESIGN_IDENTITY="-" for ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
echo "==> codesign ($IDENTITY)"
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/FortiBarHelper"
codesign --force --sign "$IDENTITY" "$APP"

echo "==> done: $APP"
