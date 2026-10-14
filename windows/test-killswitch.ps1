# Kill-switch test for AppVPN without a VPN or administrator rights: the proxy must block whenever there is no
# tunnel, and the app must not believe a stranger on the management port. The checks that need a tunnel
# (traffic flows, blocks while reconnecting, resumes) are in test-e2e.ps1. Run after a build.
# Prints one line per check and exits 1 if any check failed (2 if the test cannot run safely).
param([string]$App = "$PSScriptRoot\out\app\AppVPN.exe")
$port = 18964
$mgmt = 18965
$edge = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
$tmp = Join-Path ([IO.Path]::GetTempPath()) "appvpn-killswitch-$PID"
$failures = 0

function Check($name, $passed, $detail = '') {
    if ($passed) { Write-Host "ok   $name" } else { $script:failures++; Write-Host "FAIL $name ($detail)" }
}
function Port-Open($p) {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $p); $true } catch { $false } finally { $c.Close() }
}
function Proxied { curl.exe -s -m 8 -o NUL -x "socks5h://127.0.0.1:$port" https://example.com; $LASTEXITCODE -eq 0 }
function Quit-App {
    Get-Process AppVPN -ErrorAction SilentlyContinue | Stop-Process -Force
    for ($i = 0; $i -lt 50 -and (Port-Open $port); $i++) { Start-Sleep -Milliseconds 100 }
    -not (Port-Open $port)
}

function Dump-Dom($url, [string[]]$flags) {  # one headless Edge run in a fresh profile; returns the page it printed
    $out = "$tmp\dom-$(Get-Random).txt"
    $p = Start-Process $edge -ArgumentList (@("--user-data-dir=$tmp\edge-$(Get-Random)", '--headless=new', '--disable-gpu', '--no-first-run', '--dump-dom') + $flags + $url) -RedirectStandardOutput $out -RedirectStandardError "$out.err" -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(40000)) { $p.Kill() }
    # Only processes started with this temporary profile; never the user's own Edge.
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object CommandLine -Match ([regex]::Escape($tmp)) | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    [string](Get-Content $out -Raw -ErrorAction SilentlyContinue)  # a string even when Edge printed nothing
}

if (Get-Process openvpn -ErrorAction SilentlyContinue) { Write-Host 'OpenVPN is running. Refusing to touch a real tunnel.'; exit 2 }
if (Port-Open $mgmt) { Write-Host "Something is already listening on port $mgmt. Refusing to touch it."; exit 2 }
if (-not (Quit-App)) { Write-Host "AppVPN did not quit: port $port still accepts connections."; exit 2 }

curl.exe -s -m 15 -o NUL https://example.com
Check 'this PC reaches the internet directly, so "blocked" below means something' ($LASTEXITCODE -eq 0)

# A stranger takes the management port and reports a connection on the PC's ordinary network adapter.
$default = Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
$ip = (Get-NetIPAddress -InterfaceIndex $default.ifIndex -AddressFamily IPv4)[0].IPAddress
$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, $mgmt)
$listener.Start()
try {
    Start-Process $app
    for ($i = 0; $i -lt 100 -and -not (Port-Open $port); $i++) { Start-Sleep -Milliseconds 100 }
    Check 'AppVPN starts its proxy' (Port-Open $port)
    Check 'blocked before the tunnel is up' (-not (Proxied))

    # A browser started the way AppVPN starts it must reach nothing now. Reaching the page means it went around the proxy.
    # (Edge prints nothing when started elevated, so this runs only in an ordinary session.)
    New-Item -ItemType Directory $tmp | Out-Null
    if ((Test-Path $edge) -and (Dump-Dom 'https://example.com' @()) -match 'Example Domain') {
        $vpnFlags = "--proxy-server=socks5://127.0.0.1:$port", '"--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"', '--force-webrtc-ip-handling-policy=disable_non_proxied_udp', '--test-type'
        Check 'Edge with the VPN switches does not fall back to a direct connection' ((Dump-Dom 'https://example.com' $vpnFlags) -notmatch 'Example Domain')
    } else { Write-Host 'skip Edge check (Edge not found, or it prints no page here even without the proxy)' }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue

    $client = $null
    for ($i = 0; $i -lt 30 -and -not $client; $i++) {
        if ($listener.Pending()) { $client = $listener.AcceptTcpClient() } else { Start-Sleep -Milliseconds 100 }
    }
    if ($client) {  # it attached anyway: play OpenVPN, so the next check shows whether it also believes us
        $line = [Text.Encoding]::ASCII.GetBytes(">STATE:$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()),CONNECTED,SUCCESS,$ip,1.2.3.4,1194,,`n")
        $client.GetStream().Write($line, 0, $line.Length)
        Start-Sleep 1
    }
    Check 'the app does not attach to a management port that is not OpenVPN' (-not $client)
    Check 'still blocked while a stranger reports a connection on the normal network' (-not (Proxied))
    if ($client) { $client.Close() }
} finally { $listener.Stop() }

$quit = Quit-App
Check 'blocked when AppVPN is not running' ($quit -and -not (Proxied)) "AppVPN still listening on $port"
exit [int]($failures -gt 0)
