# AppVPN

A per-app OpenVPN client for macOS and Windows. It connects with a normal `.ovpn` profile, but only the apps you launch from AppVPN use the tunnel. Everything else on the computer keeps its normal connection, routes and DNS.

Most of this page describes the macOS app. The Windows app does the same job in the same way; what differs is in [Windows](#windows).

![AppVPN window](docs/screenshot.png)

> **Status:** the proxy, profile handling, reconnect logic and blocking are covered by tests, and CI runs an end-to-end test with a real tunnel on every push. See [Tests](#tests) and [Verifying a real connection](#verifying-a-real-connection).

## Requirements

- macOS 26 or later on Apple silicon (the UI uses Liquid Glass), or
- Windows 10 or 11, x64 or ARM (see [Windows](#windows))

Released builds need nothing else: OpenVPN is bundled inside the app.

To build from source you also need the Xcode command-line tools (Swift 5.9+) and OpenVPN 2.7+ from Homebrew (`brew install openvpn`), which the build copies into the app.

## Build and run

```bash
./build.sh
open build/AppVPN.app
```

`build.sh` compiles with SwiftPM and assembles an ad-hoc signed `build/AppVPN.app`. No Apple developer account or entitlements are needed.

The build copies Homebrew's `openvpn` and the libraries it needs into the app (`Contents/Helpers`, `Contents/Frameworks`) and relinks them to load from there, so the finished app runs on a Mac without Homebrew. Their licence texts go into `Contents/Resources/licenses`. OpenVPN itself is GPL-2.0; its source is at <https://github.com/OpenVPN/openvpn>. Each build carries whatever OpenVPN version Homebrew had at build time, so OpenVPN security updates reach users only through a new AppVPN build.

## Using it

1. **Import a profile.** Click **Import Profile…**, drop an `.ovpn` file on the window, or use **From URL…** with a direct https link. Several profiles can be kept; the pill next to Connect switches, renames and deletes them.
2. **Connect.** macOS asks for an administrator password each time, because OpenVPN needs root to create the tunnel interface.
3. **Add apps** with **+** and start them with **Launch**. Only apps launched this way use the tunnel.
4. For terminal commands, click **Copy shell proxy settings** and paste the `export …` line into the shell.

If the VPN drops, OpenVPN reconnects by itself without another password prompt. While the tunnel is down, traffic from VPN apps is blocked; it never falls back to the normal connection.

### What "coverage" means

Per-app routing here works through a local proxy, so it depends on the app honouring proxy settings.

| Label in the app | Apps | What goes through the VPN |
|---|---|---|
| All traffic and DNS | Chromium browsers (Chrome, Edge, Brave…) | Everything, in a separate VPN-only browser profile |
| Web traffic only | Electron apps (VS Code, Postman, Slack…) | Chromium traffic; background Node traffic only if the app honours proxy variables |
| May bypass the VPN | Everything else | Only what the app sends through `HTTP(S)_PROXY` / `ALL_PROXY` |

Apps with their own SOCKS5 setting can be pointed at `127.0.0.1:18964` by hand.

## How it works

```
 selected app ──► 127.0.0.1:18964 (SOCKS5 / HTTP proxy in AppVPN)
                        │  every outbound socket is pinned to the
                        │  tunnel interface with IP_BOUND_IF
                        ▼
                     utunN ──► OpenVPN (root) ──► VPN server

 everything else ──► default route (unchanged)
```

- **Tunnel.** `vpn.sh start` runs the bundled OpenVPN as a root daemon with `--route-nopull --route-noexec --dns-updown disable`, so neither pushed nor profile-defined routes and DNS are applied. The `--up` hook adds one default route *scoped* to the tunnel interface; only sockets bound to that interface can use it.
- **Proxy.** `Sources/Proxy.swift` listens on loopback and speaks SOCKS5 and HTTP (`CONNECT` and plain). It resolves names itself over the tunnel, using the DNS server the VPN pushed, so lookups don't leak to the local resolver.
- **Fail closed.** The proxy is pinned only while OpenVPN reports `CONNECTED`. In any other state, or if AppVPN is not running, proxy connections fail.
- **Control.** `Sources/VPN.swift` talks to OpenVPN over its management socket (`~/.appvpn/mgmt.sock`): state changes, disconnect, and a forced reconnect after wake from sleep.
- **Launching.** Apps are started with proxy environment variables; Chromium and Electron apps also get `--proxy-server`, `--host-resolver-rules` (no local DNS) and a WebRTC policy that forbids UDP around the proxy.

### Files

| Path | Purpose |
|---|---|
| `Sources/App.swift` | Window, UI, app launching |
| `Sources/Profiles.swift` | Profile store, import validation, profile menu, its self-test |
| `Sources/VPN.swift` | OpenVPN lifecycle over the management socket |
| `Sources/Proxy.swift` | SOCKS5/HTTP proxy pinned to the tunnel, DNS over the tunnel, its self-test |
| `vpn.sh` | Root-side launcher: `check` (profile allowlist), `start`, `up` (scoped route) |
| `build.sh` | Builds the app, bundles OpenVPN into it, optionally packages a disk image |
| `make-icon.swift`, `AppIcon.icns` | Icon generator and its output |
| `test.sh`, `test-*.sh`, `test-killswitch.py` | Tests, see below |
| `test-cases.sh` | The profiles the allowlist must accept and refuse, shared by the macOS and Windows checks |
| `windows/` | The Windows app and its tests, see [Windows](#windows) |
| `.github/workflows/release.yml` | Test on macOS and Windows and publish a release on every push to `main` |

Runtime data lives in `~/.appvpn/`: `ovpn/` (imported profiles, mode 0600), `profiles/` (VPN-only browser profiles), `openvpn.log`, `mgmt.sock`. Preferences are in the `local.appvpn` defaults domain.

## Security model

- **Profiles are untrusted and OpenVPN runs as root**, so `vpn.sh check` is an allowlist: only ordinary client directives pass. Anything that runs code, loads a library, reads or writes other files, or is unknown is refused, with the directive named in the error. The validator reads a profile exactly the way OpenVPN does, and it achieves that by refusing input where the two could disagree: quoted or backslash-escaped arguments, control characters, lines of 250 characters or more, and malformed or unterminated certificate blocks. The same check runs at import and again at connect.
- Imports must be UTF-8, at most 1 MB, contain a `remote` line and not be an HTML page. Certificate and key files referenced by a profile are inlined only if they sit in the profile's own folder. URL imports must be https.
- Profiles needing a username and password (`auth-user-pass`) are not supported and are refused at import.
- The management socket is restricted to the user who started the connection.
- Known gap, marked `ponytail:` in `vpn.sh`: the root launcher and the bundled OpenVPN run from a user-writable app bundle and prompts for the password on every connect. The upgrade path is a root-owned LaunchDaemon.

## Limits

- Not a system-wide VPN and not a kernel-level per-app VPN. Apps that ignore proxy settings (Safari, most native apps, games) are not routed. Doing that properly needs a Network Extension, which requires the paid Apple Developer Program.
- IPv4 only through the tunnel; IPv6 targets are refused rather than sent direct.
- A network switch without sleep is noticed by OpenVPN's ping timeout (60 s by default, or whatever the server pushes), not instantly.
- No menu-bar item, launch at login, traffic statistics or auto-update.
- Source comments starting with `ponytail:` mark deliberate shortcuts and their upgrade path.

## Tests

```bash
./test.sh
```

`test.sh` builds the app and runs every check that must pass before a release. It quits and relaunches AppVPN and refuses to run while a tunnel is up.

| Script | What it proves | Needs |
|---|---|---|
| `test-launcher.sh` | The profile allowlist accepts ordinary client profiles and refuses anything that could run code or touch files as root; OpenVPN accepts the options `vpn.sh` adds | Nothing (`openvpn` for the option checks) |
| `test-profiles.sh` | Import, naming, rename, delete, URL rules, inlining of certificate files | Nothing |
| `AppVPN --selftest <interface>` | SOCKS5 and HTTP proxy paths, DNS over the pinned interface, failing closed with no tunnel | Internet |
| `test-killswitch.py` | Blocking before connect, while reconnecting, after OpenVPN stops and after AppVPN quits; Chrome does not fall back to a direct connection | Internet, optional Chrome |
| `test-e2e.sh` | A real tunnel: root launcher, scoped route, untouched system routes and DNS, proxy traffic entering the tunnel while direct traffic stays out, automatic reconnect, disconnect | Passwordless `sudo` |

`test-e2e.sh` starts a throwaway OpenVPN server and client on the same machine. Because OpenVPN needs root, it runs on CI and is skipped locally unless `sudo` works without a password.

## Windows

The Windows app lives in `windows/` (C#, WPF, no packages beyond .NET). It has the same window, the same proxy on `127.0.0.1:18964` and the same guarantees: only apps launched from AppVPN use the tunnel, and they are blocked, never sent direct, while the tunnel is down.

### Install, build and run

The setup program installs AppVPN and, if the PC has no OpenVPN 2.7 or later, OpenVPN Community with it. OpenVPN cannot live inside the app as it does on macOS: the tunnel needs OpenVPN's signed driver, which only OpenVPN's own installer sets up. An older OpenVPN is upgraded, a newer one is left alone, and removing AppVPN leaves OpenVPN installed.

To build from source you need the .NET 10 SDK, and Inno Setup 6 for the setup program:

```powershell
windows\build.ps1            # out\app\AppVPN.exe
windows\build.ps1 installer  # out\AppVPN-<version>-setup.exe
```

The project also compiles on a Mac (`dotnet build windows`), which cannot run it.

Using it is the same four steps, with these differences:

- Windows asks for administrator approval on every connect. The prompt names "OpenVPN Daemon" from OpenVPN Inc., because AppVPN starts the installed OpenVPN directly.
- Apps are programs (`.exe`). **+** opens in the Start menu and accepts shortcuts.
- **Copy shell proxy settings** copies the PowerShell form (`$env:ALL_PROXY=…`).

### What is different inside

| | macOS | Windows |
|---|---|---|
| Pinning the proxy's sockets to the tunnel | `IP_BOUND_IF` | `IP_UNICAST_IF` |
| The tunnel's route | A default route scoped to the tunnel interface | A default route on the tunnel adapter with metric 9000, which loses to every real route |
| Pushed routes and DNS | `--route-nopull --route-noexec --dns-updown disable` | `--route-nopull`, and `--pull-filter ignore` for `ip-win32` and `route-method` |
| Routes and DNS written in the profile | Never applied | Removed from the profile when it is imported |
| Checking and starting as administrator | `vpn.sh` | `Allowlist.cs`, `Vpn.Start` |
| Management interface | Unix socket in `~/.appvpn` | `127.0.0.1:18965` with a new random password per connection |
| Runtime data | `~/.appvpn/` | `%LOCALAPPDATA%\AppVPN\` |

| Path | Purpose |
|---|---|
| `windows/MainWindow.xaml`, `.xaml.cs` | Window, UI, app launching |
| `windows/Profiles.cs` | Profile store, import validation, its self-test |
| `windows/Allowlist.cs` | The profile allowlist (`vpn.sh check` in C#) |
| `windows/Vpn.cs` | Starting OpenVPN as administrator, OpenVPN lifecycle over the management port |
| `windows/Proxy.cs` | SOCKS5/HTTP proxy pinned to the tunnel, DNS over the tunnel, its self-test |
| `windows/check/` | Runs `Allowlist.cs` against `test-cases.sh`; plain .NET, so it also runs on a Mac |
| `windows/build.ps1`, `installer.iss` | Builds the app and the setup program |
| `windows/test.ps1`, `test-*.ps1` | Tests, see below |

### Security on Windows

- **A stricter allowlist.** Some settings do nothing on macOS but act on Windows, so the Windows check differs from `vpn.sh` in two ways. `win-sys`, `ip-win32` and `route-method` are refused: they choose the programs OpenVPN runs as administrator and how it sets up the adapter. `route`, `route-ipv6`, `redirect-gateway`, `redirect-private`, `dhcp-option`, `dns`, `block-outside-dns`, `block-ipv6` and `register-dns` are removed from the profile at import and refused at connect, because OpenVPN on Windows has no switch to ignore them when they are written in the profile (`block-outside-dns` would block DNS for the whole PC). One parser does both, and the stored profile must pass the strict check, so a slip refuses the profile instead of letting a line through.
- **The management port is not trusted.** Any program on the PC could listen on a TCP port and report "connected". AppVPN talks to the port only while every listener on it is the installed `openvpn.exe`, and it pins the proxy only to an OpenVPN tunnel adapter, whatever the port reports.
- AppVPN and OpenVPN are both installed where only administrators can write. Known gap, marked `ponytail:` in `Vpn.cs`: OpenVPN's arguments and the profile come from the unelevated app, and Windows asks for approval on every connect. The upgrade path is a Windows service that owns the check and the start.

### Limits on Windows

- Windows has no routes scoped to one adapter. If every real network connection goes away while the tunnel adapter is still up, Windows sends other programs' traffic to the tunnel's route. The tunnel has lost its own connection to the server at that point, so the traffic goes nowhere, but this is weaker than the scoped route on macOS.
- The setup program and the app are not code-signed. SmartScreen asks before running the setup program, and PCs with Smart App Control turned on refuse it.
- Apps from the Microsoft Store cannot be started with proxy settings; only ordinary programs can be added.
- If OpenVPN is killed instead of stopped, its route stays on the disconnected tunnel adapter until the PC restarts. It is replaced on the next connect to the same VPN.
- OpenVPN security updates come from a new AppVPN setup program or from OpenVPN's own installer.

### Tests on Windows

```powershell
windows\test.ps1
```

| Script | What it proves | Needs |
|---|---|---|
| `windows/check` | The C# allowlist gives the right answer for every case in `test-cases.sh` (the list `vpn.sh` is tested with) and for the Windows-only rules | .NET SDK, `sh` (Git for Windows); also runs on a Mac |
| `AppVPN --selftest-profiles` | Import, naming, rename, delete, URL rules, inlining of certificate files, removal of routing and DNS lines | Nothing |
| `AppVPN --selftest <interface index>` | SOCKS5 and HTTP proxy paths, DNS over the pinned adapter, failing closed with no tunnel | Internet |
| `test-killswitch.ps1` | Blocking before connect and after AppVPN quits; a stranger on the management port is ignored; Edge does not fall back to a direct connection | Internet, an unelevated session for the Edge check |
| `test-e2e.ps1` | A real tunnel: start as administrator, tunnel route, untouched system routes and DNS (pushed `redirect-gateway`, DNS, `block-outside-dns`, `ip-win32` and `route-method` all dropped), proxy traffic entering the tunnel while direct traffic stays out, blocking when the server dies, automatic reconnect, disconnect | Elevated PowerShell, OpenVPN |

To check a real connection by hand: `route print -4` shows the normal default route plus one on the tunnel adapter with a metric of 9000 or more, `curl.exe -s -x socks5h://127.0.0.1:18964 ifconfig.me` prints the VPN address and `curl.exe -s ifconfig.me` your own. Troubleshooting starts with `%LOCALAPPDATA%\AppVPN\openvpn.log`.

## AI usage disclosure

AppVPN was built with [Claude Code](https://claude.com/claude-code), Anthropic's AI coding assistant. It was used to write and modify much of the source, the tests and this documentation. The maintainer directs the work and reviews the changes, and the behaviour is checked by the test suite above rather than by trust in the tooling. Because the app runs a launcher as root, read `vpn.sh` and `Sources/` (on Windows, `windows/`) yourself before trusting it with a profile that matters.

## Releases

Every push of code to `main` runs `./test.sh` on macOS and `windows\test.ps1` on Windows on GitHub Actions ([.github/workflows/release.yml](.github/workflows/release.yml)); if all checks pass on both, the build is published as release `v0.1.<run number>` with `AppVPN-<version>.dmg` and `AppVPN-<version>-setup.exe` attached (`./build.sh dmg` and `windows\build.ps1 installer` make the same files locally). Pull requests run the same tests without publishing. Changes to documentation only do not trigger a release.

To install on macOS, open the disk image and drag AppVPN to Applications. The app is ad-hoc signed and not notarized, so a downloaded copy has to be released from quarantine once before the first launch:

```bash
xattr -dr com.apple.quarantine /Applications/AppVPN.app
```

To install on Windows, run the setup program. It is not code-signed, so SmartScreen asks first: choose **More info**, then **Run anyway**.

## Verifying a real connection

1. Connect with a working profile.
2. Routing is untouched: `netstat -rn -f inet` still shows the normal default route, plus a `default` row on `utunN` with the `I` (scoped) flag.
3. The proxy exits through the VPN, the system does not:

   ```bash
   curl -s -x socks5h://127.0.0.1:18964 ifconfig.me   # VPN address
   curl -s ifconfig.me                                 # your own address
   ```

4. Sleep and wake the Mac: no password prompt, the first command fails while the app shows "Reconnecting…", then works again.

Troubleshooting starts with `~/.appvpn/openvpn.log`.
