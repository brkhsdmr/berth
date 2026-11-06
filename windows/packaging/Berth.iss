; Kullanıcı başına kurulum (yönetici izni gerekmez). Derleme: windows\scripts\package.ps1
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define BuildDir "..\build\Release"

[Setup]
AppId={{EED2DAB4-D3CC-46D2-9DF8-D1CDB824EE01}
AppName=Berth
AppVersion={#AppVersion}
AppPublisher=Burak Hasdemir
DefaultDirName={localappdata}\Programs\Berth
DefaultGroupName=Berth
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\build\dist
OutputBaseFilename=Berth-{#AppVersion}-Setup
SetupIconFile={#BuildDir}\assets\app.ico
UninstallDisplayIcon={app}\Berth.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
MinVersion=10.0.22000
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
turkish.AutoStart=Oturum açıldığında başlat
english.AutoStart=Start at sign-in
turkish.StartupGroup=Başlangıç:
english.StartupGroup=Startup:
turkish.LaunchNow=Berth'ü başlat
english.LaunchNow=Launch Berth

[Tasks]
Name: "autostart"; Description: "{cm:AutoStart}"; GroupDescription: "{cm:StartupGroup}"

[Files]
Source: "{#BuildDir}\Berth.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Berth"; Filename: "{app}\Berth.exe"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Berth"; ValueData: """{app}\Berth.exe"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\Berth.exe"; Description: "{cm:LaunchNow}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\Berth.exe"; Parameters: "--quit"; Flags: runhidden; RunOnceId: "Quit"

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\Berth"

[Code]
// Çalışan kopya kapanmadan dosya değiştirilemez.
function InitializeSetup(): Boolean;
var Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM Berth.exe /F', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := True;
end;
