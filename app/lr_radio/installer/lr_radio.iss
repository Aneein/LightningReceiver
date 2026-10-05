; Lightning Receiver FM - Inno Setup script
; Build:  powershell -File installer\build_installer.ps1
;   (flutter build windows --release, then ISCC on this file)

#define AppName "Lightning Receiver FM"
#define AppVersion "1.2.1"
#define AppExe "lr_radio.exe"
#define Repo "..\..\.."
#define Release "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6E3C2A51-4B7F-4C1E-9D8A-2F5B7C0E91A4}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Lightning Receiver
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; per-user install by default, admin install offered in a dialog
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=LR_Radio_Setup_{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
InfoBeforeFile=requirements.txt
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "chs"; MessagesFile: "ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Flutter runtime + app
Source: "{#Release}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; board tools used by the app (lr_jtagd FTDI JTAG daemon, Vivado bridge fallback, AD9361 no-OS init tool)
Source: "{#Repo}\tools\hw\lr_jtagd\lr_jtagd.exe"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#Repo}\tools\hw\lr_jtag_bridge.tcl"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "{#Repo}\tools\hw\ad9361_jtag\ad9361_jtag.exe"; DestDir: "{app}\resources"; Flags: ignoreversion
Source: "requirements.txt"; DestDir: "{app}"; DestName: "使用前提.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autoprograms}\{#AppName} 使用前提"; Filename: "{app}\使用前提.txt"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
