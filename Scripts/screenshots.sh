#!/usr/bin/env bash
# Regenerates the README screenshots from the app's built-in demo mode
# (made-up profiles; nothing from your keychain, helper or saved data).
# Needs Screen Recording permission for the terminal running it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/Resources/screenshots"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
command -v cwebp >/dev/null || { echo "cwebp not found: brew install webp" >&2; exit 1; }
mkdir -p "$OUT"

swift build >/dev/null
BIN="$ROOT/.build/debug/FortiBar"

# Window id of the biggest FortiBar window (the panel or the settings window).
window_id() {
  swift - <<'SWIFT'
import CoreGraphics
let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (Int, Double) = (0, 0)
for w in all where (w["kCGWindowOwnerName"] as? String) == "FortiBar" {
    guard let b = w["kCGWindowBounds"] as? [String: Double], let id = w["kCGWindowNumber"] as? Int else { continue }
    let area = (b["Width"] ?? 0) * (b["Height"] ?? 0)
    if area > best.1 { best = (id, area) }
}
print(best.0)
SWIFT
}

shoot() { # mode view file
  local attempt id pid
  for attempt in 1 2 3; do
    FORTIBAR_DEMO="$1" FORTIBAR_DEMO_VIEW="$2" "$BIN" >/dev/null 2>&1 &
    pid=$!
    sleep 4
    id="$(window_id)"
    if [ "$id" != "0" ]; then
      screencapture -x -l"$id" "$TMP/$3.png"
      cwebp -q 88 -m 6 -alpha_q 90 "$TMP/$3.png" -o "$OUT/$3.webp" >/dev/null 2>&1
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      sleep 2
      echo "wrote $OUT/$3.webp"
      return
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 2
  done
  echo "no window for $3" >&2
  exit 1
}

shoot disconnected panel panel-disconnected
shoot connected panel panel-connected
shoot disconnected settings settings
