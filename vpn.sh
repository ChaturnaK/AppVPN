#!/bin/sh
# Runs as root: "start" from the app's admin prompt, "up" as OpenVPN's --up hook.
# ponytail: root runs this from a user-writable bundle and asks for the password on every connect.
# Upgrade path: a root-owned LaunchDaemon (SMAppService.daemon) that owns this script.
set -eu

case "$1" in
check)
    # The profile is an untrusted download and OpenVPN runs as root, so this is an allowlist: only
    # ordinary client settings pass. Anything that runs code, loads a library, reads or writes other
    # files, or is simply unknown is refused. Routes and DNS settings are allowed because start
    # never applies them (--route-noexec, --dns-updown disable).
    bad=$(awk '
        function name(s) { gsub(/["\047]/, "", s); sub(/^--/, "", s); return s }  # the way OpenVPN reads a directive
        { sub(/\r$/, ""); w = name($1); a = 2 }
        skip { if (w == "</" skip ">") skip = ""; next }  # inside an inline certificate or key block
        w == "" || w ~ /^[#;]/ || w ~ /^<\/?connection>$/ { next }
        w ~ /^<(ca|cert|key|extra-certs|tls-auth|tls-crypt|tls-crypt-v2)>$/ { skip = substr(w, 2, length(w) - 2); next }
        w == "setenv" && name($2) == "opt" { w = name($3); a = 4; if (w == "") { print "setenv opt"; exit } }  # "setenv opt X" applies X
        w == "setenv" && name($2) !~ /^(CLIENT_CERT|FORWARD_COMPATIBLE|PUSH_PEER_INFO|GENERIC_CONFIG|ALLOW_PASSWORD_SAVE|[UI]V_[A-Za-z0-9_]+)$/ { print "setenv " $2; exit }
        w ~ /^(http|socks)-proxy$/ && $(a + 2) != "" && $(a + 2) !~ /^auto(-nct)?$/ { print w " with a credentials file"; exit }
        w ~ /^(ca|cert|key|extra-certs|tls-auth|tls-crypt|tls-crypt-v2)$/ && $a == "[inline]" { next }
        (w == "dev" && $a !~ /^u?tun[0-9]*$/) || (w == "dev-type" && $a != "tun") { print w " " $a; exit }  # tun only: no device paths
        w !~ /^(client|pull|tls-client|dev|dev-type|proto|proto-force|remote|remote-random|remote-random-hostname|resolv-retry|nobind|bind|local|lport|rport|port|float|persist-key|persist-tun|persist-local-ip|persist-remote-ip|remote-cert-tls|remote-cert-eku|remote-cert-ku|verify-x509-name|ns-cert-type|peer-fingerprint|auth|cipher|data-ciphers|data-ciphers-fallback|ncp-ciphers|ncp-disable|compress|comp-lzo|comp-noadapt|allow-compression|verb|mute|mute-replay-warnings|link-mtu|tun-mtu|tun-mtu-extra|mssfix|fragment|mtu-disc|auth-nocache|auth-retry|tls-version-min|tls-version-max|tls-cipher|tls-ciphersuites|tls-groups|tls-cert-profile|tls-timeout|key-direction|keepalive|ping|ping-restart|ping-exit|ping-timer-rem|inactive|reneg-sec|reneg-bytes|reneg-pkts|hand-window|tran-window|connect-retry|connect-retry-max|connect-timeout|server-poll-timeout|explicit-exit-notify|sndbuf|rcvbuf|socket-flags|fast-io|tcp-nodelay|push-peer-info|topology|tun-ipv6|route|route-ipv6|route-gateway|route-metric|route-delay|route-nopull|route-noexec|redirect-gateway|redirect-private|dhcp-option|dns|block-outside-dns|block-ipv6|pull-filter|ignore-unknown-option|setenv|setenv-safe|allow-recursive-routing|replay-window|disable-occ|ifconfig-nowarn|http-proxy|http-proxy-option|http-proxy-retry|socks-proxy|socks-proxy-retry|register-dns|ip-win32|route-method|win-sys)$/ { print w; exit }
    ' "$2")
    [ -z "$bad" ] || { echo "Refusing this profile: AppVPN does not allow '$bad'. OpenVPN runs as root here, so only standard client settings are accepted." >&2; exit 1; }
    ;;
start)
    profile=$2 dir=$3 user=$4
    for ovpn in /opt/homebrew/sbin/openvpn /usr/local/sbin/openvpn; do [ -x "$ovpn" ] && break; done
    [ -x "$ovpn" ] || { echo "openvpn not found (brew install openvpn)" >&2; exit 1; }
    "$0" check "$profile"
    # Old servers without cipher negotiation need the profile's cipher as fallback on OpenVPN 2.6+.
    cipher=$(awk '{ sub(/^--/, "", $1) } $1 == "cipher" { print $2; exit }' "$profile")
    # Dead-peer detection, only if the profile sets none: OpenVPN refuses --ping next to a profile's keepalive.
    dpd=$(awk '{ gsub(/["\047]/, "", $1); sub(/^--/, "", $1) } $1 ~ /^(keepalive|ping|ping-restart|ping-exit)$/ { f = 1; exit } END { if (!f) print "--ping 10 --ping-restart 60" }' "$profile")
    # --route-nopull, --route-noexec, --dns-updown disable: accept the tunnel address but apply no routes
    # or DNS, pushed or written in the profile, so the system keeps its normal path.
    # --persist-tun: keep the tunnel interface (and the scoped route on it) across automatic restarts.
    # --connect-retry / --resolv-retry: retry forever after a lost connection, 2 s apart, slowing to 30 s after repeated failures.
    # --management-hold: wait for the app to attach, so it sees every state change and error.
    exec "$ovpn" --cd "$(dirname "$profile")" --config "$profile" \
        --route-nopull --route-noexec --dns-updown disable --persist-tun \
        --connect-retry 2 30 --resolv-retry infinite $dpd \
        --script-security 2 --up "'$0' up" \
        --management "$dir/mgmt.sock" unix --management-client-user "$user" --management-hold \
        --daemon appvpn --log-append "$dir/openvpn.log" --verb 3 \
        ${cipher:+--data-ciphers-fallback "$cipher"}
    ;;
up)
    # $2 = tunnel device, $5 = tunnel local IP. A default route scoped to the tunnel: only sockets bound to it (the
    # app's proxy) use it; unbound traffic never matches. It disappears with the interface.
    # Idempotent: a re-run after an automatic restart must not fail on the route the last run left behind.
    /sbin/route -n delete -inet default -ifscope "$2" >/dev/null 2>&1 || true
    /sbin/route -n add -inet default -interface "$2" -ifscope "$2" ||
        /sbin/route -n add -inet default "${route_vpn_gateway:-$5}" -ifscope "$2"
    ;;
esac
