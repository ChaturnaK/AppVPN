#!/bin/sh
# Every check that must pass before a release. It quits and relaunches AppVPN and refuses to run
# while a tunnel is up. The end-to-end test needs passwordless sudo: it runs on CI and is skipped elsewhere.
set -eu
cd "$(dirname "$0")"

if pgrep -f sbin/openvpn >/dev/null; then echo "OpenVPN is running: disconnect first." >&2; exit 2; fi

./build.sh
sh -n vpn.sh
./test-launcher.sh
./test-profiles.sh

# The proxy self-test needs the app's port, so the app must not be running.
osascript -e 'tell application id "local.appvpn" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -x AppVPN 2>/dev/null || true
build/AppVPN.app/Contents/MacOS/AppVPN --selftest "$(route -n get default | awk '/interface:/ { print $2 }')"

python3 test-killswitch.py

if sudo -n true 2>/dev/null; then
    ./test-e2e.sh
else
    echo "skip end-to-end test (needs passwordless sudo; it runs on CI)"
fi
echo "All checks passed."
