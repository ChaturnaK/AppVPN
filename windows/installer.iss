; AppVPN's setup program: installs AppVPN for all users and, if this PC has no OpenVPN 2.7 or later, OpenVPN's
; own installer with it (the tunnel driver can only come from there). Built by "build.ps1 installer", once for
; each kind of PC: Arch is x64 or arm64.
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
; The x64 setup also runs on ARM PCs, where Windows emulates the program; the arm64 setup is for ARM PCs only.
; OpenVPN is always installed in the PC's own architecture.
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
OutputDir=out
OutputBaseFilename=AppVPN-{#Version}-{#Arch}-setup
SetupIconFile=AppIcon.ico
UninstallDisplayIcon={app}\AppVPN.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Files]
Source: "out\app\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
#if Arch == "x64"
Source: "out\OpenVPN-amd64.msi"; Flags: dontcopy
#endif
Source: "out\OpenVPN-arm64.msi"; Flags: dontcopy

[InstallDelete]
; What an earlier setup left behind. The x64 and arm64 builds differ in a few files, and one kind must not load the other's.
Type: files; Name: "{app}\*.dll"

[Icons]
Name: "{autoprograms}\AppVPN"; Filename: "{app}\AppVPN.exe"

[Run]
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
function OpenVpnFeatures: String;
var
  Major, Minor: Cardinal;
begin
  if InstalledOpenVpn(Major, Minor) then Result := '' else Result := ' {#Features}';
end;

{ OpenVPN first: without it AppVPN cannot connect, so if its installer fails, setup stops here and says so. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Msi: String;
  Code: Integer;
begin
  Result := '';
  if not NeedsOpenVpn then Exit;
  if IsArm64 then Msi := 'OpenVPN-arm64.msi' else Msi := 'OpenVPN-amd64.msi';
  ExtractTemporaryFile(Msi);
  if not Exec(ExpandConstant('{sys}\msiexec.exe'), '/i "' + ExpandConstant('{tmp}\' + Msi) + '" /qn /norestart' + OpenVpnFeatures, '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Code := -1;
  if Code = 3010 then
    NeedsRestart := True
  else if Code <> 0 then
    Result := 'OpenVPN could not be installed (its installer returned code ' + IntToStr(Code) + '), so AppVPN was not installed either. Close other installers and run this setup again, or install OpenVPN 2.7 from openvpn.net first.';
end;
