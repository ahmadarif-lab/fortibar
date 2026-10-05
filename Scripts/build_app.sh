#!/bin/bash
# Build FortiBar.app into dist/ — bundles the fortivpn CLI (MIT,
# a3660980/fortivpn-client-cli) which drives FortiClient over FortiTray's
# control socket, so the app has no external runtime dependency.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release

APP="$ROOT/dist/FortiBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/.build/release/FortiBar" "$APP/Contents/MacOS/FortiBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

CLI="$ROOT/../fortivpn-client-cli/.build/release/fortivpn"
if [ -x "$CLI" ]; then
  cp "$CLI" "$APP/Contents/Resources/fortivpn"
  echo "==> bundled fortivpn CLI"
else
  echo "!! fortivpn CLI not found at $CLI — app will fall back to /usr/local/bin"
fi

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "(codesign skipped)"

echo "==> done: $APP"
