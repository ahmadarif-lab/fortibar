#!/bin/sh
# Installs (or removes) the FortiBar privileged helper as a root LaunchDaemon.
# Needs root: the app runs it through the system admin prompt (Touch ID), or:
#   sudo Scripts/install-helper.sh install <path-to-FortiBarHelper> <uid>
#   sudo Scripts/install-helper.sh uninstall
set -eu

LABEL=com.fortibar.helper
BIN=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

[ "$(id -u)" = 0 ] || { echo "harus dijalankan sebagai root" >&2; exit 1; }

stop() {
  launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
}

case "${1:-}" in
  install)
    SRC="${2:?path helper}"; UID_ALLOWED="${3:?uid}"
    case "$UID_ALLOWED" in ''|*[!0-9]*) echo "uid tidak valid" >&2; exit 1 ;; esac
    [ -x "$SRC" ] || { echo "helper tidak ditemukan: $SRC" >&2; exit 1; }
    stop
    install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
    install -o root -g wheel -m 755 "$SRC" "$BIN"
    cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$BIN</string><string>--uid</string><string>$UID_ALLOWED</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>StandardErrorPath</key><string>/var/log/fortibar-helper.log</string>
	<key>StandardOutPath</key><string>/var/log/fortibar-helper.log</string>
</dict>
</plist>
PLISTEOF
    chown root:wheel "$PLIST"; chmod 644 "$PLIST"
    launchctl bootstrap system "$PLIST"
    echo "helper terpasang"
    ;;
  uninstall)
    stop
    rm -f "$PLIST" "$BIN" /var/run/fortibar-helper.sock
    echo "helper dihapus"
    ;;
  *)
    echo "usage: $0 install <helper> <uid> | uninstall" >&2; exit 2 ;;
esac
