#!/bin/sh
# Tests ProfileStore (import, rename, delete, checks) against dummy fixtures. Run after ./build.sh.
set -eu
cd "$(dirname "$0")"

tmp=$(mktemp -d)
srv=
trap '[ -z "$srv" ] || kill "$srv" 2>/dev/null; rm -rf "$tmp"' EXIT
mkdir "$tmp/fixtures"
f="$tmp/fixtures"

# Dummy content only: no real keys or certificates.
printf 'client\ndev tun\nremote vpn.example.com 1194\n<ca>\nFAKE\n</ca>\n' > "$f/good.ovpn"
printf 'client\ndev tun\nremote vpn.example.com 1194\nroute-up /tmp/x.sh\n' > "$f/script.ovpn"
printf '<html><body>Sign in</body></html>\n' > "$f/page.ovpn"
printf 'client\ndev tun\n' > "$f/noremote.ovpn"
printf 'client\nremote vpn.example.com 1194\nauth-user-pass\n' > "$f/userpass.ovpn"
printf 'client\nremote vpn.example.com 1194\nca ca.crt\n' > "$f/external.ovpn"
printf -- '-----BEGIN CERTIFICATE-----\nFAKE CA\n-----END CERTIFICATE-----\n' > "$f/ca.crt"
printf 'client\r\nremote vpn.example.com 1194\r\n<ca>\r\nFAKE\r\nCA\r\n</ca>\r\n' > "$f/crlf.ovpn"
printf 'client\nremote vpn.example.com 1194\n"up" /tmp/x.sh\n' > "$f/quoted.ovpn"
printf 'client\nremote vpn.example.com 1194\nsetenv opt up /tmp/x.sh\n' > "$f/setenvopt.ovpn"
printf 'client\nremote vpn.example.com 1194\n<up>\n/tmp/x.sh\n</up>\n' > "$f/block.ovpn"
printf 'client\nremote vpn.example.com 1194\nca /etc/hosts\n' > "$f/outside.ovpn"
cp "$f/good.ovpn" "$f/1700000000000.ovpn"
dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr '\0' 'a' > "$f/big.ovpn"

python3 -m http.server 8765 --bind 127.0.0.1 --directory "$f" >/dev/null 2>&1 &
srv=$!
for _ in $(seq 50); do curl -sf -o /dev/null http://127.0.0.1:8765/good.ovpn && break; sleep 0.1; done

status=0
build/AppVPN.app/Contents/MacOS/AppVPN --selftest-profiles "$tmp" || status=$?
exit $status
