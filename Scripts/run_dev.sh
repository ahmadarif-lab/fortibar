#!/usr/bin/env bash
# Quick iteration loop: runs the menu bar app straight from `swift run`.
# Differences from the packaged app: a temporary Dock icon, no login item,
# and an unsigned binary, so the keychain may ask for access to saved
# credentials. The helper (if installed) is shared with the packaged app.
#
#   Scripts/run_dev.sh                       # normal run
#   FORTIBAR_DEMO=connected Scripts/run_dev.sh   # made-up profiles, nothing real touched
#   FORTIBAR_VERSION=0.0.1 Scripts/run_dev.sh    # pretend to be an old version to see the update banner
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift build --product FortiBarHelper >/dev/null   # so "Install helper" finds it next to the app
exec swift run FortiBar
