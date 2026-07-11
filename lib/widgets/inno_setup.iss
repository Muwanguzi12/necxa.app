; Inno Setup script for Necxa
; See https://jrsoftware.org/isinfo.php for documentation.

#define MyAppName "Necxa"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Necxa, Inc."
#define MyAppURL "https://necxa.app"
#define MyAppExeName "necxa_flutter.exe"

[Setup]
AppId={{AUTO}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=.\build\windows\installer
OutputBaseFilename=Necxa-Windows-Setup-{#MyAppVersion}
SetupIconFile=.\windows\runner\resources\app_icon.ico
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: ".\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon