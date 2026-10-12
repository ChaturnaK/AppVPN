# Every check that must pass before a release, like test.sh on macOS. It closes and restarts AppVPN and refuses
# to run while a tunnel is up. The end-to-end test needs an elevated PowerShell and OpenVPN installed: it runs
# on CI and is skipped elsewhere unless both are there.
# With the .NET SDK present it builds the app first; otherwise it tests the build already in out\app
# (or the AppVPN.exe given, such as an installed one).
param([string]$App = "$PSScriptRoot\out\app\AppVPN.exe")
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$failed = $false

if (Get-Process openvpn -ErrorAction SilentlyContinue) { Write-Host 'OpenVPN is running: disconnect first.'; exit 2 }

# AppVPN is a windowed program, so its output only shows when it is sent somewhere.
function Run-App([string[]]$arguments) {
    $out = New-TemporaryFile
    $p = Start-Process $app -ArgumentList $arguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out
    Get-Content $out | Out-Host
    Remove-Item $out
    if ($p.ExitCode -ne 0) { $script:failed = $true }
}
function Text($path, $text) { [IO.File]::WriteAllText($path, $text) }  # exact bytes: no byte-order mark, no CRLF

if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    & "$PSScriptRoot\build.ps1"
    if (Get-Command sh -ErrorAction SilentlyContinue) {
        $cases = Join-Path ([IO.Path]::GetTempPath()) "appvpn-cases-$PID"
        sh check/export-cases.sh ($cases -replace '\\', '/')
        dotnet run --project check -- $cases
        if ($LASTEXITCODE -ne 0) { $failed = $true }
        Remove-Item -Recurse -Force $cases
    } else { Write-Host 'skip allowlist cases (needs sh, e.g. from Git for Windows; they run on CI and on the Mac)' }
} else { Write-Host 'skip build and allowlist cases (no .NET SDK here; they run on CI and on the Mac)' }
if (-not (Test-Path $app)) { Write-Host "No build at $app."; exit 2 }

# ProfileStore (import, rename, delete, checks) against dummy fixtures: no real keys or certificates.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "appvpn-profiles-$PID"
$f = "$tmp\fixtures"
New-Item -ItemType Directory $f | Out-Null
Text "$f\good.ovpn" "client`ndev tun`nremote vpn.example.com 1194`n<ca>`nFAKE`n</ca>`n"
Text "$f\script.ovpn" "client`ndev tun`nremote vpn.example.com 1194`nroute-up /tmp/x.sh`n"
Text "$f\page.ovpn" "<html><body>Sign in</body></html>`n"
Text "$f\noremote.ovpn" "client`ndev tun`n"
Text "$f\userpass.ovpn" "client`nremote vpn.example.com 1194`nauth-user-pass`n"
Text "$f\external.ovpn" "client`nremote vpn.example.com 1194`nca ca.crt`n"
Text "$f\ca.crt" "-----BEGIN CERTIFICATE-----`nFAKE CA`n-----END CERTIFICATE-----`n"
Text "$f\crlf.ovpn" "client`r`nremote vpn.example.com 1194`r`n<ca>`r`nFAKE`r`nCA`r`n</ca>`r`n"
Text "$f\quoted.ovpn" "client`nremote vpn.example.com 1194`n`"up`" /tmp/x.sh`n"
Text "$f\setenvopt.ovpn" "client`nremote vpn.example.com 1194`nsetenv opt up /tmp/x.sh`n"
Text "$f\block.ovpn" "client`nremote vpn.example.com 1194`n<up>`n/tmp/x.sh`n</up>`n"
Text "$f\outside.ovpn" "client`nremote vpn.example.com 1194`nca C:/Windows/win.ini`n"
Text "$f\routes.ovpn" "client`nremote vpn.example.com 1194`nredirect-gateway def1`nsetenv opt block-outside-dns`ndhcp-option DNS 1.1.1.1`nverb 3`n"
Text "$f\winsys.ovpn" "client`nremote vpn.example.com 1194`nwin-sys C:/x`n"
Copy-Item "$f\good.ovpn" "$f\1700000000000.ovpn"
Text "$f\big.ovpn" ('a' * 1100000)
# Profile 3 is new: not in Local State yet.
'Default', 'Profile 2', 'Profile 3', 'System Profile' | ForEach-Object { New-Item -ItemType Directory "$tmp\browser\$_" | Out-Null }
Text "$tmp\browser\Local State" '{"profile":{"info_cache":{"Profile 2":{"name":"Work"},"Default":{"name":"Me"}}}}'
Run-App '--selftest-profiles', $tmp
Remove-Item -Recurse -Force $tmp

# The proxy self-test needs the app's port, so the app must not be running.
Get-Process AppVPN -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 1
Run-App '--selftest', (Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1).ifIndex

& "$PSScriptRoot\test-killswitch.ps1" $App
if ($LASTEXITCODE -ne 0) { $failed = $true }

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
if ($elevated -and (Test-Path 'HKLM:\SOFTWARE\OpenVPN')) {
    & "$PSScriptRoot\test-e2e.ps1" $App
    if ($LASTEXITCODE -ne 0) { $failed = $true }
} else { Write-Host 'skip end-to-end test (needs an elevated PowerShell and OpenVPN installed; it runs on CI)' }

if ($failed) { Write-Host 'Some checks FAILED.'; exit 1 }
Write-Host 'All checks passed.'
