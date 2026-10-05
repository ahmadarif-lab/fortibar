#!/bin/bash
# Pasang ulang FortiBar, lalu sembunyikan ikon menu bar FortiTray
# (hide_system_tray_icon di fctsysconf.plist) supaya cuma ada satu menubar Forti.
set -euo pipefail

echo "==> 1/4 build + install FortiBar"
cd "$HOME/projects/fortibar"
./Scripts/build_app.sh >/dev/null
pkill -f "FortiBar.app/Contents/MacOS/FortiBar" 2>/dev/null || true
rm -rf /Applications/FortiBar.app
cp -R dist/FortiBar.app /Applications/
echo "    /Applications/FortiBar.app terpasang"

echo "==> 2/4 sembunyikan ikon tray FortiClient"
P="/Library/Application Support/Fortinet/FortiClient/conf/fctsysconf.plist"
sudo cp "$P" "$P.fortibar-backup"
sudo plutil -replace hide_system_tray_icon -bool YES "$P"
plutil -p "$P" | grep -i hide_system_tray

echo "==> 3/4 restart FortiTray supaya setting-nya kebaca"
pkill -x FortiTray 2>/dev/null || true
sleep 2
open -gj "/Applications/FortiClient.app/Contents/Resources/runtime.helper/FortiClientAgent.app/Contents/Resources/FortiTray/FortiTray.app"
sleep 4

echo "==> 4/4 verifikasi"
pgrep -x FortiTray >/dev/null && echo "    FortiTray jalan: ya" || echo "    FortiTray jalan: TIDAK"
/usr/local/bin/fortivpn doctor --json 2>/dev/null | tr ',' '\n' | grep -E '"name"|"status"' | paste - -
open /Applications/FortiBar.app
echo "    FortiBar dijalankan"
