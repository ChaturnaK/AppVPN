# End-to-end test with a real OpenVPN server and client on this PC: tunnel, tunnel route, per-app routing through
# the proxy, automatic reconnect and disconnect. Needs an elevated PowerShell in the account that is signed in,
# and OpenVPN installed (CI). It brings up tunnel adapters and routes and removes them again. Run after a build.
$app = "$PSScriptRoot\out\app\AppVPN.exe"
$dir = "$env:LOCALAPPDATA\AppVPN"
$log = "$dir\openvpn.log"
$proxy = '127.0.0.1:18964'
$mgmt = 18965
$unroutable = '198.51.100.7'  # TEST-NET-2: nothing answers, which is all the packet counters need

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')) { Write-Host 'This test needs an elevated PowerShell.'; exit 2 }
$ovpn = (Get-ItemProperty 'HKLM:\SOFTWARE\OpenVPN' -ErrorAction SilentlyContinue).exe_path
if (-not $ovpn) { Write-Host 'OpenVPN is not installed.'; exit 2 }
if (Get-Process openvpn -ErrorAction SilentlyContinue) { Write-Host 'OpenVPN is already running: refusing to touch it.'; exit 2 }
$openssl = @("$(Split-Path $ovpn)\openssl.exe", (Get-Command openssl -ErrorAction SilentlyContinue).Source) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $openssl) { Write-Host 'This test needs openssl (OpenVPN installs it as "OpenSSL utilities").'; exit 2 }
$tap = (Get-NetAdapter | Where-Object InterfaceDescription -Like 'TAP-Windows Adapter V9*' | Select-Object -First 1).Name
if (-not $tap) { Write-Host 'This test needs the TAP-Windows adapter for its server (the client uses the DCO adapter).'; exit 2 }

$t = Join-Path ([IO.Path]::GetTempPath()) "appvpn-e2e-$PID"
$tf = $t -replace '\\', '/'
New-Item -ItemType Directory $t, $dir -Force | Out-Null
$fail = $false
$server = $null

function Check($name, [scriptblock]$test) { if (& $test) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:fail = $true } }
function Wait-For($seconds, [scriptblock]$test) { for (; $seconds -gt 0; $seconds--) { if (& $test) { return $true }; Start-Sleep 1 }; $false }
function Quit-App { Get-Process AppVPN -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1 }
function Client { Get-CimInstance Win32_Process -Filter "Name='openvpn.exe'" | Where-Object CommandLine -Match 'client\.ovpn' }
function Up-Count { if (Test-Path $log) { @(Select-String 'Initialization Sequence Completed' $log).Count } else { 0 } }
function Start-Server { $script:server = Start-Process $ovpn -ArgumentList "--config $tf/server.conf --log $tf/server.log" -WindowStyle Hidden -PassThru }
function Default-Route { Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1 | ForEach-Object { "$($_.NextHop) on $($_.ifIndex)" } }
function Dns { ((Get-DnsClientServerAddress -AddressFamily IPv4 | ForEach-Object { "$($_.InterfaceAlias)=$($_.ServerAddresses -join ',')" }) -join ' ') + " rules=$(@(Get-DnsClientNrptRule).Count)" }
function Tunnel-Route { Get-NetRoute -DestinationPrefix 0.0.0.0/0 -InterfaceAlias $dev -ErrorAction SilentlyContinue }
function Out-Packets {  # once the adapter's own chatter has stopped
    do { $n = (Get-NetAdapterStatistics -Name $dev).SentUnicastPackets; Start-Sleep 2 } while ((Get-NetAdapterStatistics -Name $dev).SentUnicastPackets -ne $n)
    $n
}
function Via-Proxy { curl.exe -s -m 4 -o NUL -x "socks5://$proxy" "http://$unroutable/"; $LASTEXITCODE }
# curl exits 28 (timeout) when the proxy sent the connection into the tunnel, and with a proxy
# error straight away when the proxy refused it because the tunnel is not up.
function Proxy-Refuses { $code = Via-Proxy; $code -ne 0 -and $code -ne 28 }
function Enters-Tunnel { $a = Out-Packets; $code = Via-Proxy; Start-Sleep -Milliseconds 300; $code -eq 28 -and (Get-NetAdapterStatistics -Name $dev).SentUnicastPackets -gt $a }

try {
    # Throwaway CA, server and client certificates.
    [IO.File]::WriteAllText("$t\openssl.cnf", "[req]`ndistinguished_name=dn`n[dn]`n")
    $env:OPENSSL_CONF = "$t\openssl.cnf"
    Push-Location $t
    cmd /c "`"$openssl`" req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -subj `"/CN=AppVPN test CA`" -addext basicConstraints=critical,CA:TRUE -days 2 2>>setup.log"
    foreach ($n in 'server', 'client') {
        cmd /c "`"$openssl`" req -newkey rsa:2048 -nodes -keyout $n.key -out $n.csr -subj /CN=$n 2>>setup.log"
        [IO.File]::WriteAllText("$t\$n.ext", "keyUsage=digitalSignature,keyEncipherment`nextendedKeyUsage=${n}Auth`n")
        cmd /c "`"$openssl`" x509 -req -in $n.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out $n.crt -days 2 -extfile $n.ext 2>>setup.log"
    }
    Pop-Location

    # The server pushes what a real provider pushes, and what would hurt on Windows; the client must take the address and nothing else.
    [IO.File]::WriteAllText("$t\server.conf", @"
dev tun
dev-node "$tap"
disable-dco
proto udp
local 127.0.0.1
port 11940
topology subnet
server 10.99.0.0 255.255.255.0
ca $tf/ca.crt
cert $tf/server.crt
key $tf/server.key
dh none
keepalive 2 6
push "redirect-gateway def1"
push "dhcp-option DNS 10.99.0.1"
push "block-outside-dns"
push "register-dns"
push "ip-win32 netsh"
push "route-method exe"
verb 3
"@)
    $pem = { param($f) ([IO.File]::ReadAllText("$t\$f") -replace "`r", '').Trim() }
    [IO.File]::WriteAllText("$t\client.ovpn", "client`ndev tun`nproto udp`nremote 127.0.0.1 11940`nnobind`nremote-cert-tls server`n<ca>`n$(& $pem ca.crt)`n</ca>`n<cert>`n$(& $pem client.crt)`n</cert>`n<key>`n$(& $pem client.key)`n</key>`n")

    Quit-App
    $beforeRoute = Default-Route
    $beforeDns = Dns

    Start-Server
    Check 'test server starts' { Wait-For 30 { (Test-Path "$t\server.log") -and (Select-String -Quiet 'Initialization Sequence Completed' "$t\server.log") } }
    $start = Start-Process $app -ArgumentList '--start', "$t\client.ovpn" -PassThru -NoNewWindow -RedirectStandardOutput "$t\start.txt"
    $null = $start.Handle  # without this PowerShell forgets the exit code
    $start.WaitForExit()  # not -Wait: that would also wait for the OpenVPN it leaves running
    Check 'the launcher starts OpenVPN, held until the app attaches' { $start.ExitCode -eq 0 -and (Wait-For 10 { Get-NetTCPConnection -LocalPort $mgmt -State Listen -ErrorAction SilentlyContinue }) -and (Up-Count) -eq 0 }
    # Through Explorer when there is a desktop, so the app runs unelevated as it does for a user.
    if (Get-Process explorer -ErrorAction SilentlyContinue) { explorer.exe $app } else { Start-Process $app }
    Check 'the tunnel comes up once the app attaches' { Wait-For 40 { (Up-Count) -ge 1 } }
    $dev = if ((Get-Content $log -Raw) -match 'device \[([^\]]+)\] opened') { $Matches[1] }
    Start-Sleep 2  # let the app pin the proxy

    Check "the tunnel adapter ($dev) gets a default route that loses to every real one" { (Tunnel-Route).RouteMetric -ge 8000 }
    Check 'the system default route is unchanged' { (Default-Route) -eq $beforeRoute }
    Check 'the pushed redirect-gateway is not applied' { -not (Get-NetRoute -AddressFamily IPv4 | Where-Object DestinationPrefix -In '0.0.0.0/1', '128.0.0.0/1') }
    Check 'system DNS is unchanged (servers and name-resolution rules)' { (Dns) -eq $beforeDns }
    Check 'the pushed adapter settings (ip-win32, route-method) are dropped' { @(Select-String "Pushed option removed by filter: '(ip-win32|route-method)" $log).Count -eq 2 }
    Check 'the rest of the PC still resolves names and reaches the internet directly' { (Resolve-DnsName example.com -ErrorAction SilentlyContinue) -and $(curl.exe -s -m 20 -o NUL https://example.com; $LASTEXITCODE -eq 0) }

    # Direct traffic as a burst far larger than the adapter's own chatter (name lookups and the like), so the byte counter can tell the two apart.
    $udp = New-Object Net.Sockets.UdpClient
    $before = (Get-NetAdapterStatistics -Name $dev).SentBytes
    1..200 | ForEach-Object { [void]$udp.Send((New-Object byte[] 1000), 1000, $unroutable, 9) }
    $udp.Close()
    Start-Sleep 1
    Check 'direct traffic stays off the tunnel' { (Get-NetAdapterStatistics -Name $dev).SentBytes - $before -lt 100000 }
    Check 'traffic through the proxy enters the tunnel' { Enters-Tunnel }

    Stop-Process -Id $server.Id -Force
    Check 'when the server dies the proxy blocks instead of falling back' { Wait-For 25 { Proxy-Refuses } }
    Start-Server
    Check 'it reconnects by itself, with no approval prompt' { Wait-For 60 { (Up-Count) -ge 2 } }
    Start-Sleep 2
    Check 'the tunnel route is in place after reconnecting' { (Tunnel-Route).RouteMetric -ge 8000 }
    Check 'traffic through the proxy enters the tunnel again' { Enters-Tunnel }

    Quit-App  # frees the management interface's single connection
    $m = New-Object Net.Sockets.TcpClient ('127.0.0.1', $mgmt)
    foreach ($line in (Get-Content "$dir\mgmt.pw" -Raw).Trim(), 'signal SIGTERM') {
        $bytes = [Text.Encoding]::ASCII.GetBytes("$line`n")
        $m.GetStream().Write($bytes, 0, $bytes.Length)
        Start-Sleep 1
    }
    Check 'the user can stop OpenVPN over the management port' { Wait-For 10 { -not (Client) } }
    $m.Close()
    Check "the tunnel's route is gone after disconnecting" { -not (Tunnel-Route) }
    Check 'the system default route is still unchanged' { (Default-Route) -eq $beforeRoute }
    Check 'system DNS is still unchanged' { (Dns) -eq $beforeDns }
} catch {
    Write-Host "FAIL the test stopped: $_"
    $fail = $true
} finally {
    if ($fail) {
        Write-Host '--- setup'; Get-Content "$t\setup.log", "$t\start.txt" -ErrorAction SilentlyContinue | Select-Object -Last 15
        Write-Host '--- client log'; Get-Content $log -Tail 40 -ErrorAction SilentlyContinue
        Write-Host '--- server log'; Get-Content "$t\server.log" -Tail 20 -ErrorAction SilentlyContinue
        Write-Host '--- routes'; Get-NetRoute -AddressFamily IPv4 | Where-Object DestinationPrefix -Match '/[01]$' | Format-Table DestinationPrefix, NextHop, InterfaceAlias, RouteMetric | Out-String
    }
    Quit-App
    Get-CimInstance Win32_Process -Filter "Name='openvpn.exe'" | Where-Object CommandLine -Match 'appvpn-e2e|client\.ovpn' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep 1
    Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue
}
exit [int]$fail
