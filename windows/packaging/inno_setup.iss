; ══════════════════════════════════════════════════════════════
; Necxa Windows Installer — Inno Setup Script
; https://jrsoftware.org/isinfo.php
; ══════════════════════════════════════════════════════════════

#define MyAppName      "Necxa"
#define MyAppPublisher "Necxa Ltd"
#define MyAppURL       "https://necxa.app"
#define MyAppExeName   "necxa_flutter.exe"
#define MyAppSupportURL "https://necxa.app/support"

; Version is injected by CI via /DMyAppVersion=x.y.z
; Falls back to 1.0.0 for local builds
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

[Setup]
; ── Identity ─────────────────────────────────────────────────
; Fixed GUID — do NOT change this after first release.
; Changing it causes Windows to treat reinstalls as new programs.
AppId={{8F3C2A1D-4B7E-4F9A-BC22-D1E5F6A083CC}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppSupportURL}
AppUpdatesURL={#MyAppURL}

; ── OS Requirement ───────────────────────────────────────────
; Flutter 3.x requires Windows 10 (build 10.0.17763+)
MinVersion=10.0.17763

; ── Install Paths ─────────────────────────────────────────────
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes

; ── Output ───────────────────────────────────────────────────
; {#SourcePath} = the directory containing this .iss file.
; Output goes to build/windows/installer/ relative to repo root.
OutputDir={#SourcePath}\..\..\build\windows\installer
OutputBaseFilename=Necxa-Windows-Setup-{#MyAppVersion}

; ── Appearance ───────────────────────────────────────────────
SetupIconFile={#SourcePath}\..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName} {#MyAppVersion}
WizardStyle=modern
WizardResizable=yes

; ── Compression ───────────────────────────────────────────────
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes

; ── Privileges ───────────────────────────────────────────────
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

; ── Misc ─────────────────────────────────────────────────────
AllowNoIcons=yes
CloseApplications=yes
RestartApplications=no
UsePreviousAppDir=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Optional desktop shortcut shown during install wizard
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Flutter 3.10+ outputs to build\windows\x64\runner\Release\
Source: "{#SourcePath}\..\..\build\windows\x64\runner\Release\*"; \
  DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Start Menu
Name: "{group}\{#MyAppName}";              Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}";    Filename: "{uninstallexe}"
; Desktop (only if user opted in)
Name: "{autodesktop}\{#MyAppName}";        Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Offer to launch app immediately after install completes
Filename: "{app}\{#MyAppExeName}"; \
  Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; \
  Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Clean up any residual data written by the app on uninstall
Type: dirifempty; Name: "{localappdata}\{#MyAppName}"