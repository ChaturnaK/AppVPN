#!/bin/sh
# End-to-end test with a real OpenVPN server and client on this machine: tunnel, scoped route,
# per-app routing through the proxy, automatic reconnect and disconnect. OpenVPN needs root, so this
# needs passwordless sudo (CI). It creates tunnel interfaces and routes and removes them again.
# Run after ./build.sh.
set -eu
cd "$(dirname "$0")"

app=$PWD/build/AppVPN.app
vpn=$app/Contents/Resources/vpn.sh
for ovpn in /opt/homebrew/sbin/openvpn /usr/local/sbin/openvpn; do [ -x "$ovpn" ] && break; done
dir=$HOME/.appvpn
log=$dir/openvpn.log
proxy=127.0.0.1:18964
unroutable=198.51.100.7  # TEST-NET-2: nothing answers, which is all the packet counters need

sudo -n true
if pgrep -f sbin/openvpn >/dev/null; then echo "OpenVPN is already running: refusing to touch it." >&2; exit 2; fi
t=$(mktemp -d /tmp/appvpn-e2e.XXXXXX)
mkdir -p "$dir"
fail=0
web=

check() { name=$1; shift; if "$@"; then echo "ok   $name"; else echo "FAIL $name"; fail=1; fi; }
wait_for() { n=$1; shift; while [ "$n" -gt 0 ]; do "$@" && return 0; n=$((n - 1)); sleep 1; done; return 1; }  # seconds, command
quit_app() { osascript -e 'tell application id "local.appvpn" to quit' >/dev/null 2>&1 || true; sleep 1; pkill -x AppVPN 2>/dev/null || true; }

cleanup() {
    if [ $? != 0 ] || [ "$fail" != 0 ]; then  # also when set -e stopped the script before any check
        echo "--- setup"; cat "$t/setup.log" 2>/dev/null || true
        echo "--- client log"; tail -n 40 "$log" || true
        echo "--- server log"; tail -n 20 "$t/server.log" || true
        echo "--- routes"; netstat -rn -f inet | head -n 30
    fi
    quit_app
    for pid in $(pgrep -f "$t/" || true); do sudo kill "$pid" 2>/dev/null || true; done
    [ -z "$web" ] || kill "$web" 2>/dev/null || true
    sleep 1
    sudo rm -rf "$t"
    rm -f "$dir/mgmt.sock"
}
trap cleanup EXIT

# Throwaway CA, server and client certificates.
cd "$t"
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -subj "/CN=AppVPN test CA" -days 2 2>>setup.log
for n in server client; do
    openssl req -newkey rsa:2048 -nodes -keyout $n.key -out $n.csr -subj "/CN=$n" 2>>setup.log
    printf 'keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=%sAuth\n' $n > $n.ext
    openssl x509 -req -in $n.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out $n.crt -days 2 -extfile $n.ext 2>>setup.log
done
cd - >/dev/null

# The server pushes what a real provider pushes; the client must take the address and nothing else.
cat > "$t/server.conf" <<EOF
dev tun
proto udp
local 127.0.0.1
port 11940
topology subnet
server 10.99.0.0 255.255.255.0
ca $t/ca.crt
cert $t/server.crt
key $t/server.key
dh none
keepalive 2 6
push "redirect-gateway def1"
push "dhcp-option DNS 10.99.0.1"
verb 3
EOF
{
    printf 'client\ndev tun\nproto udp\nremote 127.0.0.1 11940\nnobind\nremote-cert-tls server\n'
    printf '<ca>\n%s\n</ca>\n<cert>\n%s\n</cert>\n<key>\n%s\n</key>\n' "$(cat "$t/ca.crt")" "$(cat "$t/client.crt")" "$(cat "$t/client.key")"
} > "$t/client.ovpn"

start_server() { sudo "$ovpn" --config "$t/server.conf" --daemon --log-append "$t/server.log" --writepid "$t/server.pid"; }
default_route() { route -n get default | awk '/gateway:|interface:/ { printf "%s ", $2 }'; }
dns() { scutil --dns | awk '/nameserver/ { print $3 }' | sort -u | tr '\n' ' '; }
scoped() { netstat -rn -f inet | awk -v d="$dev" '$1 == "default" && $4 == d && $3 ~ /I/ { f = 1 } END { exit !f }'; }
out_packets() { netstat -I "$dev" -b -n | awk '$3 ~ /^10\.99/ { print $8; exit }'; }
via_proxy() { code=0; curl -s -m 4 -o /dev/null -x "socks5://$proxy" "http://$unroutable/" || code=$?; echo "$code"; }
# curl exits 28 (timeout) when the proxy sent the connection into the tunnel, and with a proxy
# error straight away when the proxy refused it because the tunnel is not up.
proxy_refuses() { code=$(via_proxy); [ "$code" != 0 ] && [ "$code" != 28 ]; }
enters_tunnel() { a=$(out_packets); code=$(via_proxy); b=$(out_packets); [ "$code" = 28 ] && [ "$b" -gt "$a" ]; }

quit_app
before_route=$(default_route)
before_dns=$(dns)
: > "$log"
: > "$t/server.log"
rm -f "$dir/mgmt.sock"

start_server
check "test server starts" wait_for 15 grep -q "Initialization Sequence Completed" "$t/server.log"
sudo "$vpn" start "$t/client.ovpn" "$dir" "$(id -un)"
check "the root launcher starts OpenVPN, held until the app attaches" wait_for 10 test -S "$dir/mgmt.sock"
open -g "$app"
check "the tunnel comes up once the app attaches" wait_for 40 grep -q "Initialization Sequence Completed" "$log"
dev=$(grep -o 'Opened utun device utun[0-9]*' "$log" | tail -n 1 | awk '{ print $4 }')
sleep 2  # let the app pin the proxy, and the new interface finish its own chatter

check "the up hook adds a default route scoped to ${dev:-the tunnel}" scoped
check "the system default route is unchanged" test "$(default_route)" = "$before_route"
no_redirect() { ! netstat -rn -f inet | grep -qE '^(0/1|128\.0/1)[[:space:]]'; }
check "the pushed redirect-gateway is not applied" no_redirect
check "system DNS is unchanged" test "$(dns)" = "$before_dns"
check "the rest of the Mac still reaches the internet directly" curl -s -m 20 -o /dev/null https://example.com

# Direct first: after the proxied attempt the proxy keeps retrying its connection into the tunnel
# for a few seconds, which would show up in the counter.
c=$(out_packets); curl -s -m 4 -o /dev/null "http://$unroutable/" || true; d=$(out_packets)
check "direct traffic stays off the tunnel" test "$d" = "$c"
check "traffic through the proxy enters the tunnel" enters_tunnel

# Both ends of this tunnel are on one host, so the kernel may short-circuit a full round trip.
python3 -m http.server 8099 --bind 10.99.0.1 >/dev/null 2>&1 &
web=$!
sleep 1
if curl -s -m 6 -o /dev/null -x "socks5://$proxy" http://10.99.0.1:8099/; then
    echo "info an HTTP round trip through the tunnel works"
else
    echo "info no HTTP round trip through the tunnel (expected when both ends share a host)"
fi

sudo kill "$(cat "$t/server.pid")"
check "when the server dies the proxy blocks instead of falling back" wait_for 25 proxy_refuses
check "the tunnel interface and its scoped route survive the restart" scoped
start_server
connected_twice() { [ "$(grep -c 'Initialization Sequence Completed' "$log")" -ge 2 ]; }
check "it reconnects by itself, with no password prompt" wait_for 60 connected_twice
dev=$(grep -o 'Opened utun device utun[0-9]*' "$log" | tail -n 1 | awk '{ print $4 }')
sleep 2
check "the scoped route is in place after reconnecting" scoped
check "traffic through the proxy enters the tunnel again" enters_tunnel

quit_app  # frees the management interface's single connection
printf 'signal SIGTERM\n' | nc -U "$dir/mgmt.sock" >/dev/null 2>&1 || true
stopped() { ! pgrep -f "$t/client.ovpn" >/dev/null; }
check "the user can stop the root daemon over the management socket" wait_for 10 stopped
no_tunnel_route() { ! netstat -rn -f inet | awk -v d="$dev" '$4 == d { f = 1 } END { exit !f }'; }
check "the tunnel's routes are gone after disconnecting" no_tunnel_route
check "the system default route is still unchanged" test "$(default_route)" = "$before_route"

exit $fail
