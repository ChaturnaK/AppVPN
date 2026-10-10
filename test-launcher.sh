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
pre=  # bytes put before the profile
long=$(printf %0300d 0)  # longer than OpenVPN reads in one piece

allowed() {  # name, extra profile lines
    printf %b "$pre$base$2" > "$t/p.ovpn"
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
allowed "directives after an inline block" '<ca>\nabc\n</ca>\nnobind\nverb 3\n'
allowed "trailing comments" 'verb 3 # note\nremote b.example.com 443 ; backup\n'
allowed "comment line starting with ;" '; just a note\n'
allowed "tabs between arguments" 'verb\t3\nkeepalive\t10\t60\n'
allowed "CRLF line endings around an inline block" '<ca>\r\nabc\r\n</ca>\r\nverb 3\r\n'
allowed "closing tag preceded by spaces" '<ca>\nabc\n  \t</ca>\nverb 3\n'
allowed "a 249-character line" "# $(printf %0247d 0)\n"
pre='\0357\0273\0277'; allowed "UTF-8 byte-order mark on the first line" ''; pre=

refused "up script" 'up /tmp/x.sh\n' "'up'"
refused "quoted directive name" '"down" /tmp/x.sh\n' "quotes or backslashes"
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

# Where awk and OpenVPN read a profile differently, a directive can hide from the allowlist.
refused "closing tag with text glued on, then a forbidden directive" '<ca>\nabc\n</ca>x\nup /tmp/x.sh\n' "'up'"
refused "unterminated inline block" '<ca>\nabc\nup /tmp/x.sh\n' "unterminated <ca> block"
refused "opening tag followed by more text" '<ca> extra\nup /tmp/x.sh\n</ca>\n' "'<ca>'"
refused "opening tag with leading dashes" '--<ca>\nup /tmp/x.sh\n</ca>\n' "'<ca>'"
refused "proxy credentials file in glued quotes" 'http-proxy proxy.example.com 8080 "auto""/etc/passwd"\n' "quotes or backslashes"
refused "proxy credentials file behind a vertical tab" 'http-proxy proxy.example.com 8080\v/etc/passwd\n' "control character"
refused "double quote" 'verb "3"\n' "quotes or backslashes"
refused "single quote" "verb '3'\n" "quotes or backslashes"
refused "backslash" 'verb 3 \\ x\n' "quotes or backslashes"
refused "carriage return inside a line" 'verb 3\rup /tmp/x.sh\n' "control character"
refused "NUL byte" '#\0 x\n' "control character"
refused "semicolon inside a word is not a comment" 'nobind;up /tmp/x.sh\n' "'nobind;up'"
refused "300-character line outside a block" "# $long\n" "longer than 249"
refused "300-character line inside a block" "<ca>\n$long\n</ca>\n" "longer than 249"
refused "control character inside a block" '<ca>\nab\vcd\n</ca>\n' "control character"

# OpenVPN validates options before it needs root, so "start" with a dummy profile shows whether the
# options vpn.sh adds are accepted next to what a profile may already set. It always stops at the
# missing CA; what must not appear is a conflict or an unrecognised option.
bundled=${vpn%/Resources/vpn.sh}/Helpers/openvpn
if [ -x "$bundled" ]; then
    # Both what the files say they load and what the loader really loads: nothing from Homebrew.
    refs=$(otool -L "$bundled" "${vpn%/Resources/vpn.sh}"/Frameworks/*.dylib | grep -cE '^[[:space:]]+/(opt|usr/local)/' || true)
    loaded=$(DYLD_PRINT_LIBRARIES=1 "$bundled" --version 2>&1 | grep -cE '/(opt|usr/local)/' || true)
    if [ "$refs" = 0 ] && [ "$loaded" = 0 ] && "$bundled" --version | grep -q '^OpenVPN 2'; then
        echo "ok   bundled OpenVPN runs using only libraries inside the app"
    else
        echo "FAIL bundled OpenVPN runs using only libraries inside the app ($refs references, $loaded loaded from outside)"; fail=1
    fi
else
    echo "skip bundled OpenVPN check (the app was built without it)"
fi

if [ -x "$bundled" ] || [ -x /opt/homebrew/sbin/openvpn ] || [ -x /usr/local/sbin/openvpn ]; then
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
