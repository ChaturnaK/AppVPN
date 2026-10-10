# Builds out\app (AppVPN and the .NET it needs; nothing to install to run it).
# VERSION=1.2.3 in the environment sets the version.
# "build.ps1 installer" also packages out\AppVPN-<version>-setup.exe, which installs OpenVPN when it is missing.
# "build.ps1 openvpn" installs the same OpenVPN the installer carries on this PC (elevated), for the tests.
param([string]$What = '')
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# The OpenVPN the setup program carries. Users get OpenVPN security updates only through a new AppVPN setup, or from OpenVPN's own installer.
$openvpn = '2.7.8-I001'
$sha256 = @{ amd64 = '1EA61A3056905B90607D4B0F084C04E5CF3043E07CF192D9CD44B0474F29CC49'; arm64 = '6FC0E8899CC5275EE297FB837BC84AA2BC49F8EF96D7AD93EE3FEE1E7163A25C' }
# The program and both tunnel drivers (DCO, and TAP for profiles DCO cannot run, such as ones with an old cipher). Not OpenVPN's own tray app.
$features = 'ADDLOCAL=OpenVPN,Drivers,Drivers.OvpnDco,Drivers.TAPWindows6'

function Get-OpenVpn($arch) {  # OpenVPN's own signed installer, from its own server, checked against the hash above
    $msi = "$PSScriptRoot\out\OpenVPN-$arch.msi"
    if (-not (Test-Path $msi) -or (Get-FileHash $msi).Hash -ne $sha256[$arch]) {
        New-Item -ItemType Directory out -Force | Out-Null
        curl.exe -sSfL -o $msi "https://swupdate.openvpn.net/community/releases/OpenVPN-$openvpn-$arch.msi"
        if ((Get-FileHash $msi).Hash -ne $sha256[$arch]) { Remove-Item $msi; throw "OpenVPN-$openvpn-$arch.msi does not match its expected SHA-256." }
    }
    $msi
}

if ($What -eq 'openvpn') {
    $msi = Get-OpenVpn $(if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' })
    $p = Start-Process msiexec -ArgumentList "/i `"$msi`" /qn /norestart $features,OpenSSL" -Wait -PassThru  # openssl makes the end-to-end test's certificates
    if ($p.ExitCode -ne 0) { throw "OpenVPN's installer failed with code $($p.ExitCode)." }
    return
}

dotnet publish -c Release -o out\app --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
Write-Host 'Built out\app'

if ($What -eq 'installer') {
    Get-OpenVpn amd64 | Out-Null
    Get-OpenVpn arm64 | Out-Null
    $iscc = @((Get-Command iscc -ErrorAction SilentlyContinue).Source) + (Get-Item "${env:ProgramFiles(x86)}\Inno Setup*\ISCC.exe", "$env:ProgramFiles\Inno Setup*\ISCC.exe" -ErrorAction SilentlyContinue).FullName | Where-Object { $_ } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup is needed to build the setup program (https://jrsoftware.org/isinfo.php).' }
    & $iscc /Qp "/DFeatures=$features" installer.iss
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed.' }
}
