#!/bin/bash
# End-to-end smoke test of the privileged helper (no sudo needed once the
# helper is installed): connect with a FortiToken code, run a command through
# the tunnel, disconnect.
#
#   Scripts/test-helper.sh creds.txt ["command to run through the tunnel"]
#
# creds.txt lines:  host: <gateway>   username: <user>   pre-shared key: <psk>   password: <pw>
set -euo pipefail
CREDS="${1:?usage: Scripts/test-helper.sh creds.txt [command]}"
CMD="${2:-true}"

OTP="$(osascript -e 'text returned of (display dialog "FortiToken code NOW (6 digits):" default answer "" buttons {"Cancel","OK"} default button "OK")' 2>/dev/null || true)"
[ -n "$OTP" ] || { echo "cancelled"; exit 1; }

OTP="$OTP" CREDS="$CREDS" CMD="$CMD" python3 - <<'PY'
import json, os, socket, subprocess, sys

SOCK = "/var/run/fortibar-helper.sock"
m = {"host": "gateway", "username": "username", "pre-shared key": "psk", "password": "password"}
c = {}
for line in open(os.environ["CREDS"], encoding="utf-8"):
    k, sep, v = line.partition(":")
    if sep and k.strip().lower() in m:
        c[m[k.strip().lower()]] = v.strip()

IKE = ("aes128-sha256-modp1536,aes256-sha256-modp1536,aes128-sha1-modp1536,aes256-sha1-modp1536,"
       "aes128-sha256-modp1024,aes256-sha256-modp1024,aes128-sha1-modp1024,aes256-sha1-modp1024,3des-sha1-modp1024")
ESP = ("aes128-sha256-modp1536,aes256-sha256-modp1536,aes128-sha1-modp1536,aes256-sha1-modp1536,"
       "aes128-sha256-modp2048,aes256-sha256-modp2048,aes128-sha256-modp1024,aes256-sha256-modp1024,"
       "aes128-sha256,aes256-sha256,aes128-sha1,aes256-sha1,3des-sha1")

def call(req, timeout=100):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(timeout)
    s.connect(SOCK)
    s.sendall((json.dumps(req) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    return json.loads(data)

print("ping:", call({"cmd": "ping"}))
req = {"cmd": "connect", "connect": {
    "name": "Test", "gateway": c["gateway"], "peerID": "", "username": c["username"],
    "ike": IKE, "esp": ESP, "routes": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
    "lanExceptions": [], "psk": c["psk"], "password": c["password"], "otp": os.environ["OTP"]}}
r = call(req)
print("connect:", json.dumps(r, indent=1))
ok = r.get("ok")
try:
    if ok:
        print("status:", call({"cmd": "status"}))
        print("$", os.environ["CMD"])
        p = subprocess.run(os.environ["CMD"], shell=True, capture_output=True, text=True, timeout=60)
        print(p.stdout + p.stderr, "exit =", p.returncode)
finally:
    if ok:
        print("disconnect:", call({"cmd": "disconnect"}, 60))
        print("status:", call({"cmd": "status"}))
PY
netstat -rn -f inet | grep -E "^(10|172.16|192.168)/" || echo "(no leftover VPN routes)"; pgrep -lf charon || echo "(no charon)"
