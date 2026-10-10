#!/usr/bin/env python3
"""Kill-switch test for AppVPN. Plays OpenVPN's management interface, so the app's reconnect
and blocking behaviour is checked without root or a real VPN. Run after ./build.sh.
Prints one line per check and exits 1 if any check failed (2 if the test cannot run safely)."""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

PROJECT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(PROJECT, "build", "AppVPN.app")
SOCK = os.path.expanduser("~/.appvpn/mgmt.sock")
PORT = 18964
URL = "https://example.com"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
CHROME_FLAGS = [
    "--proxy-server=socks5://127.0.0.1:18964",
    "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1",
    "--force-webrtc-ip-handling-policy=disable_non_proxied_udp",
]
PROFILE_PREFIX = "appvpn-killswitch-"

failures = 0


def check(name, passed, detail=""):
    global failures
    if passed:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name} ({detail})")


def run(*args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def port_open():
    with socket.socket() as s:
        s.settimeout(0.5)
        try:
            s.connect(("127.0.0.1", PORT))
            return True
        except OSError:
            return False


def quit_app():
    """Quit AppVPN, then wait (max 5 s) until its proxy port stops accepting connections."""
    run("osascript", "-e", 'tell application id "local.appvpn" to quit')
    for attempt in range(2):
        deadline = time.time() + 5
        while port_open() and time.time() < deadline:
            time.sleep(0.1)
        if not port_open():
            return True
        run("pkill", "-x", "AppVPN")  # the polite quit did not land (e.g. Apple Events not permitted on CI)
    return False


def proxied(url=URL):
    return run("curl", "-s", "-m", "15", "-o", "/dev/null", "-x", f"socks5h://127.0.0.1:{PORT}", url).returncode == 0


def read_for(sock, seconds):
    """Collect whatever the app writes over about `seconds`."""
    data = b""
    end = time.time() + seconds
    while time.time() < end:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            continue
        if not chunk:
            break
        data += chunk
    return data.decode(errors="replace")


def dump_dom(url):
    """One headless Chrome run through the proxy, in a fresh profile. Returns the DOM it printed."""
    profile = tempfile.mkdtemp(prefix=PROFILE_PREFIX)
    try:
        try:
            out = run(CHROME, f"--user-data-dir={profile}", *CHROME_FLAGS, "--headless=new", "--disable-gpu",
                      "--no-first-run", "--dump-dom", url, timeout=40).stdout
        except subprocess.TimeoutExpired as e:
            out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        return out
    finally:
        # Only processes started with this temp profile; never the user's own Chrome.
        run("pkill", "-f", profile)
        shutil.rmtree(profile, ignore_errors=True)


def main():
    if run("pgrep", "-f", "sbin/openvpn").returncode == 0:
        print("OpenVPN is running (pgrep -f sbin/openvpn). Refusing to touch a real tunnel.")
        return 2
    os.makedirs(os.path.dirname(SOCK), exist_ok=True)
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.connect(SOCK)
        print(f"Something is already listening on {SOCK}. Refusing to touch it.")
        return 2
    except OSError:
        pass  # nothing listening
    finally:
        probe.close()

    # The fake tunnel IP is the default interface's own address, so the app pins the proxy to a link with real connectivity.
    route = run("route", "-n", "get", "default").stdout
    iface = next((line.split()[-1] for line in route.splitlines() if "interface:" in line), "en0")
    ip = run("ipconfig", "getifaddr", iface).stdout.strip()
    if not ip:
        print(f"This test needs {iface} to have an IPv4 address (used as the fake tunnel IP).")
        return 2

    if not quit_app():
        print(f"AppVPN did not quit: port {PORT} still accepts connections. Quit it and rerun.")
        return 2
    if os.path.exists(SOCK):
        os.remove(SOCK)  # stale: nothing was listening

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client = None
    try:
        server.bind(SOCK)
        server.listen(1)
        subprocess.run(["open", "-g", APP], check=True)
        server.settimeout(10)
        try:
            client, _ = server.accept()
        except socket.timeout:
            check("AppVPN attaches to the management socket", False, "no connection within 10 s")
            return 1
        client.settimeout(0.2)
        client.sendall(b">INFO:OpenVPN Management Interface Version 6 -- type 'help' for more info\n"
                       b">HOLD:Waiting for hold release:0\n")
        sent = read_for(client, 1.0)
        check("hold off sent before hold release",
              "hold off" in sent and "hold release" in sent and sent.index("hold off") < sent.index("hold release"),
              repr(sent))
        check("state notifications requested", "state on" in sent, repr(sent))

        def state(name, state_ip=""):
            client.sendall(f">STATE:{int(time.time())},{name},SUCCESS,{state_ip},1.2.3.4,1194,,\n".encode())
            time.sleep(0.6)

        check("blocked before the tunnel is up", not proxied())
        state("CONNECTED", ip)
        check("traffic flows when connected", proxied())
        state("RECONNECTING")
        check("blocked while reconnecting", not proxied())
        state("WAIT")
        state("AUTH")
        check("still blocked during re-handshake", not proxied())
        state("CONNECTED", ip)
        check("traffic resumes after reconnect", proxied())

        if os.path.exists(CHROME):
            out = dump_dom("https://1.1.1.1/")
            check("Chrome reaches the internet through the proxy",
                  "1.1.1.1" in out or "cloudflare" in out.lower(), f"{len(out)} bytes of DOM")
            state("RECONNECTING")
            out = dump_dom("https://1.1.1.1/")
            check("Chrome does not fall back to a direct connection",
                  "cloudflare" not in out.lower(), "Cloudflare page loaded while RECONNECTING")
            state("CONNECTED", ip)
        else:
            print("skip Chrome checks (Google Chrome not found)")

        client.close()
        client = None  # simulates OpenVPN dying
        time.sleep(0.6)
        check("blocked after OpenVPN stops", not proxied())

        quit_ok = quit_app()
        check("blocked when AppVPN is not running", quit_ok and not proxied(), f"AppVPN still listening on {PORT}")
    finally:
        if client is not None:
            client.close()
        server.close()
        if os.path.exists(SOCK):
            os.remove(SOCK)
        run("pkill", "-f", PROFILE_PREFIX)  # any headless Chrome left with one of our temp profiles
        subprocess.run(["open", "-g", APP])  # leave AppVPN running

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
