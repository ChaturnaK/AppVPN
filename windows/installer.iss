; AppVPN's setup program: installs AppVPN for all users and, if this PC has no OpenVPN 2.7 or later, OpenVPN's
; own installer with it (the tunnel driver can only come from there). Built by "build.ps1 installer".
#define Version GetEnv("VERSION")
#if Version == ""
  #define Version "0.1"
#endif

[Setup]
AppId={{7C0F3D52-5A0B-4E57-9C55-0D8C7E2A41B6}
AppName=AppVPN
AppVersion={#Version}
AppPublisher=AppVPN
DefaultDirName={autopf}\AppVPN
DisableProgramGroupPage=yes
PrivilegesRequired=admin
; The program is x64 and also runs on ARM PCs; OpenVPN is installed in the PC's own architecture.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=out
OutputBaseFilename=AppVPN-{#Version}-setup
SetupIconFile=AppIcon.ico
UninstallDisplayIcon={app}\AppVPN.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Files]
Source: "out\app\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
Source: "out\OpenVPN-amd64.msi"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: NeedsOpenVpn and not IsArm64
Source: "out\OpenVPN-arm64.msi"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: NeedsOpenVpn and IsArm64

[Icons]
Name: "{autoprograms}\AppVPN"; Filename: "{app}\AppVPN.exe"

[Run]
Filename: "msiexec.exe"; Parameters: "/i ""{tmp}\OpenVPN-amd64.msi"" /qn /norestart{code:OpenVpnFeatures}"; StatusMsg: "Installing OpenVPN..."; Check: NeedsOpenVpn and not IsArm64
Filename: "msiexec.exe"; Parameters: "/i ""{tmp}\OpenVPN-arm64.msi"" /qn /norestart{code:OpenVpnFeatures}"; StatusMsg: "Installing OpenVPN..."; Check: NeedsOpenVpn and IsArm64
Filename: "{app}\AppVPN.exe"; Description: "Start AppVPN"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
function InstalledOpenVpn(var Major, Minor: Cardinal): Boolean;
var
  Exe: String;
  MS, LS: Cardinal;
begin
  Result := RegQueryStringValue(HKLM64, 'SOFTWARE\OpenVPN', 'exe_path', Exe) and GetVersionNumbers(Exe, MS, LS);
  Major := MS shr 16;
  Minor := MS and $FFFF;
end;

{ No OpenVPN, or one older than 2.7. A newer one is never touched. }
function NeedsOpenVpn: Boolean;
var
  Major, Minor: Cardinal;
begin
  Result := not InstalledOpenVpn(Major, Minor) or (Major < 2) or ((Major = 2) and (Minor < 7));
end;

{ A fresh install gets only what AppVPN needs. An older OpenVPN is upgraded as it is: naming features would remove the user's others, such as OpenVPN GUI. }
function OpenVpnFeatures(Param: String): String;
var
  Major, Minor: Cardinal;
begin
  if InstalledOpenVpn(Major, Minor) then Result := '' else Result := ' {#Features}';
end;
