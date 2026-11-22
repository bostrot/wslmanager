#define MyAppName "WSL2 Distro Manager"
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
; Which build sits in payload\. The x64 installer stays "x64compatible" so it
; keeps installing on Arm64 machines under emulation exactly as before; the
; Arm64 installer is offered alongside it and is the one WinGet hands an Arm64
; PC. Both carry the same AppId, so either upgrades the other in place.
#ifndef TargetArch
  #define TargetArch "x64"
#endif
#if TargetArch == "arm64"
  #define ArchitectureIdentifiers "arm64"
  #define OutputName "wsl2-distro-manager-setup-arm64"
#elif TargetArch == "x64"
  #define ArchitectureIdentifiers "x64compatible"
  #define OutputName "wsl2-distro-manager-setup"
#else
  #error TargetArch must be "x64" or "arm64"
#endif

#include "CodeDependencies.iss"

[Setup]
AppId={{E4CB01D9-BD26-4D65-A2A7-7EAFD519B2A5}
AppName={#MyAppName}
AppVersion={#AppVersion}
AppPublisher=Bostrot
DefaultDirName={autopf}\WSL2 Distro Manager
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=.
OutputBaseFilename={#OutputName}
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed={#ArchitectureIdentifiers}
ArchitecturesInstallIn64BitMode={#ArchitectureIdentifiers}
PrivilegesRequired=admin
WizardStyle=modern
UninstallDisplayIcon={app}\wsl2distromanager.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
Source: "payload\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\wsl2distromanager.exe"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\wsl2distromanager.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\wsl2distromanager.exe"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
function InitializeSetup: Boolean;
begin
  Dependency_AddVC2015To2022;
  Result := True;
end;