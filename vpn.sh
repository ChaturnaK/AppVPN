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
    # Whatever awk does not see, OpenVPN may still run, so awk must split words and find block ends exactly
    # as OpenVPN does. Rather than copy OpenVPN's quoting rules, profiles where the two could differ are refused.
    # ponytail: a profile that quotes an argument (verify-x509-name "C=US, O=x") or has a comment with an
    # apostrophe is refused. Upgrade path: a tokeniser that implements OpenVPN's parse_line quoting rules.
    [ -r "$2" ] || { echo "Cannot read the profile '$2'." >&2; exit 1; }
    bad=$(export LC_ALL=C; tr '\000' '\001' < "$2" | awk '  # bytes, not characters; a NUL byte would cut a line short for awk, so it becomes \001
        function name(s) { return s ~ /^--./ ? substr(s, 3) : s }  # OpenVPN drops a leading -- from a directive
        function refuse(what) { print what; refused = 1; exit }
        NR == 1 { sub(/^\357\273\277/, "") }  # OpenVPN skips a UTF-8 byte-order mark
        { sub(/\r$/, "") }
        length($0) > 249 { refuse("a line longer than 249 characters") }  # OpenVPN reads 255 bytes at a time: the rest of a longer line becomes a new "line"
        /[\001-\010\013-\037\177]/ { refuse("a control character") }  # OpenVPN splits words on \v, \f and \r too; awk does not
        skip { if ($0 ~ ("^[ \t]*</" skip ">")) skip = ""; next }  # inside an inline block, which ends at a line that starts with the closing tag
        /["\047\\]/ { refuse("quotes or backslashes") }  # no quoting rules to copy: with none, a word is text between blanks
        { sub(/(^|[ \t])[#;].*$/, ""); w = name($1); a = 2 }  # a word that starts with # or ; begins a comment
        NF == 0 || (NF == 1 && $1 ~ /^<\/?connection>$/) { next }
        NF == 1 && $1 ~ /^<(ca|cert|key|extra-certs|tls-auth|tls-crypt|tls-crypt-v2)>$/ { skip = substr($1, 2, length($1) - 2); next }  # only a line that is just the tag opens a block
        w == "setenv" && name($2) == "opt" { w = name($3); a = 4; if (w == "") refuse("setenv opt") }  # "setenv opt X" applies X
        w == "setenv" && name($2) !~ /^(CLIENT_CERT|FORWARD_COMPATIBLE|PUSH_PEER_INFO|GENERIC_CONFIG|ALLOW_PASSWORD_SAVE|[UI]V_[A-Za-z0-9_]+)$/ { refuse("setenv " $2) }
        w ~ /^(http|socks)-proxy$/ && $(a + 2) != "" && $(a + 2) !~ /^auto(-nct)?$/ { refuse(w " with a credentials file") }
        w ~ /^(ca|cert|key|extra-certs|tls-auth|tls-crypt|tls-crypt-v2)$/ && $a == "[inline]" { next }
        (w == "dev" && $a !~ /^u?tun[0-9]*$/) || (w == "dev-type" && $a != "tun") { refuse(w " " $a) }  # tun only: no device paths
        w !~ /^(client|pull|tls-client|dev|dev-type|proto|proto-force|remote|remote-random|remote-random-hostname|resolv-retry|nobind|bind|local|lport|rport|port|float|persist-key|persist-tun|persist-local-ip|persist-remote-ip|remote-cert-tls|remote-cert-eku|remote-cert-ku|verify-x509-name|ns-cert-type|peer-fingerprint|auth|cipher|data-ciphers|data-ciphers-fallback|ncp-ciphers|ncp-disable|compress|comp-lzo|comp-noadapt|allow-compression|verb|mute|mute-replay-warnings|link-mtu|tun-mtu|tun-mtu-extra|mssfix|fragment|mtu-disc|auth-nocache|auth-retry|tls-version-min|tls-version-max|tls-cipher|tls-ciphersuites|tls-groups|tls-cert-profile|tls-timeout|key-direction|keepalive|ping|ping-restart|ping-exit|ping-timer-rem|inactive|reneg-sec|reneg-bytes|reneg-pkts|hand-window|tran-window|connect-retry|connect-retry-max|connect-timeout|server-poll-timeout|explicit-exit-notify|sndbuf|rcvbuf|socket-flags|fast-io|tcp-nodelay|push-peer-info|topology|tun-ipv6|route|route-ipv6|route-gateway|route-metric|route-delay|route-nopull|route-noexec|redirect-gateway|redirect-private|dhcp-option|dns|block-outside-dns|block-ipv6|pull-filter|ignore-unknown-option|setenv|setenv-safe|allow-recursive-routing|replay-window|disable-occ|ifconfig-nowarn|http-proxy|http-proxy-option|http-proxy-retry|socks-proxy|socks-proxy-retry|register-dns|ip-win32|route-method|win-sys)$/ { refuse(w) }
        END { if (skip && !refused) print "unterminated <" skip "> block" }
    ')
    [ -z "$bad" ] || { echo "Refusing this profile: AppVPN does not allow '$bad'. OpenVPN runs as root here, so only standard client settings are accepted." >&2; exit 1; }
    ;;
start)
    profile=$2 dir=$3 user=$4
    # The copy bundled in the app first; an installed one only if the app was built without it.
    for ovpn in "$(dirname "$0")/../Helpers/openvpn" /opt/homebrew/sbin/openvpn /usr/local/sbin/openvpn; do [ -x "$ovpn" ] && break; done
    [ -x "$ovpn" ] || { echo "OpenVPN is missing from this build of AppVPN and is not installed (brew install openvpn)." >&2; exit 1; }
    "$0" check "$profile"
    # Old servers without cipher negotiation need the profile's cipher as fallback on OpenVPN 2.6+.
    cipher=$(awk '{ sub(/\r$/, ""); sub(/^--/, "", $1) } $1 == "cipher" { print $2; exit }' "$profile")
    # Dead-peer detection, only if the profile sets none: OpenVPN refuses --ping next to a profile's keepalive.
    dpd=$(awk '{ sub(/^--/, "", $1) } $1 ~ /^(keepalive|ping|ping-restart|ping-exit)$/ { f = 1; exit } END { if (!f) print "--ping 10 --ping-restart 60" }' "$profile")
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
