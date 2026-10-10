#!/bin/sh
# Tests vpn.sh without root: the profile allowlist, and that OpenVPN accepts the command line it builds.
# Run after ./build.sh. Dummy profiles only.
set -eu
cd "$(dirname "$0")"

vpn=$PWD/build/AppVPN.app/Contents/Resources/vpn.sh
t=$(mktemp -d /tmp/appvpn-launcher.XXXXXX)  # short: unix socket paths are limited to about 100 characters
trap 'rm -rf "$t"' EXIT
fail=0

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

. ./test-cases.sh

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
