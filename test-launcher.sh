#!/bin/sh
# Tests vpn.sh without root: the profile allowlist, and that OpenVPN accepts the command line it builds.
# Run after ./build.sh. Dummy profiles only.
set -eu
cd "$(dirname "$0")"

vpn=$PWD/build/AppVPN.app/Contents/Resources/vpn.sh
t=$(mktemp -d /tmp/appvpn-launcher.XXXXXX)  # short: unix socket paths are limited to about 100 characters
trap 'rm -rf "$t"' EXIT
fail=0
base='client\ndev tun\nproto udp\nremote vpn.example.com 1194\n'

allowed() {  # name, extra profile lines
    printf %b "$base$2" > "$t/p.ovpn"
    if "$vpn" check "$t/p.ovpn" 2>/dev/null; then echo "ok   allowed: $1"; else echo "FAIL allowed: $1"; fail=1; fi
}

refused() {  # name, extra profile lines, text the error must contain
    printf %b "$base$2" > "$t/p.ovpn"
    if msg=$("$vpn" check "$t/p.ovpn" 2>&1); then
        echo "FAIL refused: $1 (was accepted)"; fail=1
    elif printf %s "$msg" | grep -qF -- "$3"; then
        echo "ok   refused: $1"
    else
        echo "FAIL refused: $1 (message: $msg)"; fail=1
    fi
}

allowed "plain client profile" ''
allowed "common directives" 'nobind\npersist-tun\nremote-cert-tls server\ncipher AES-256-GCM\nauth SHA512\nverb 3\nkeepalive 10 60\n'
allowed "inline blocks, whatever they contain" '<ca>\n-----BEGIN CERTIFICATE-----\nup down plugin\n-----END CERTIFICATE-----\n</ca>\n<tls-crypt>\nabc\n</tls-crypt>\n'
allowed "routes and DNS (never applied)" 'redirect-gateway def1\ndhcp-option DNS 1.1.1.1\nroute 10.0.0.0 255.0.0.0\n'
allowed "setenv forms OpenVPN Connect profiles use" 'setenv opt block-outside-dns\nsetenv CLIENT_CERT 0\n'
allowed "leading dashes and CRLF line endings" '--nobind\r\nverb 3\r\n'
allowed "connection block" '<connection>\nremote b.example.com 443 tcp\n</connection>\n'
allowed "proxy without a credentials file" 'http-proxy proxy.example.com 8080\nsocks-proxy 127.0.0.1 1080\n'

refused "up script" 'up /tmp/x.sh\n' "'up'"
refused "quoted directive name" '"down" /tmp/x.sh\n' "'down'"
refused "dashed directive name" '--route-up /tmp/x.sh\n' "'route-up'"
refused "directive after an inline block" '<ca>\nabc\n</ca>\nplugin /tmp/x.so\n' "'plugin'"
refused "setenv opt smuggling a directive" 'setenv opt up /tmp/x.sh\n' "'up'"
refused "setenv of an arbitrary variable" 'setenv PATH /tmp\n' "'setenv PATH'"
refused "unknown inline block" '<up>\n/tmp/x.sh\n</up>\n' "'<up>'"
refused "log file" 'log /etc/x\n' "'log'"
refused "script-security" 'script-security 3\n' "'script-security'"
refused "management interface" 'management 127.0.0.1 7505\n' "'management'"
refused "device path" 'dev-node /dev/disk0\n' "'dev-node'"
refused "tap device" 'dev tap0\n' "'dev tap0'"
refused "proxy credentials file" 'http-proxy proxy.example.com 8080 /etc/passwd\n' "credentials file"
refused "username and password" 'auth-user-pass\n' "'auth-user-pass'"
refused "crypto engine" 'engine dynamic\n' "'engine'"
refused "unknown directive" 'frobnicate 1\n' "'frobnicate'"

# OpenVPN validates options before it needs root, so "start" with a dummy profile shows whether the
# options vpn.sh adds are accepted next to what a profile may already set. It always stops at the
# missing CA; what must not appear is a conflict or an unrecognised option.
if [ -x /opt/homebrew/sbin/openvpn ] || [ -x /usr/local/sbin/openvpn ]; then
    for extra in '' 'keepalive 10 60\n' '--keepalive 10 60\n' 'ping 5\n' 'cipher AES-256-CBC\n'; do
        printf %b "$base$extra" > "$t/p.ovpn"
        : > "$t/openvpn.log"  # with --daemon, OpenVPN reports option errors here rather than on stderr
        out=$("$vpn" start "$t/p.ovpn" "$t" "$(id -un)" 2>&1 || true)$(cat "$t/openvpn.log")
        name="start: OpenVPN accepts our options with profile line '$(printf %b "$extra" | tr -d '\n')'"
        if printf %s "$out" | grep -qiE 'conflict|unrecognized option'; then
            echo "FAIL $name ($out)"; fail=1
        elif printf %s "$out" | grep -q 'CA'; then
            echo "ok   $name"
        else
            echo "FAIL $name (expected to stop at the missing CA: $out)"; fail=1
        fi
    done
else
    echo "skip start checks (openvpn is not installed)"
fi

exit $fail
