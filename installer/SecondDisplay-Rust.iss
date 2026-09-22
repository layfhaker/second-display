; SecondDisplay Rust Host installer (Inno Setup 6).
; Built with scripts\build-installers.ps1.

#define MyAppName "SecondDisplay (Rust)"
#define MyAppPublisher "SecondDisplay"
#define HostExeName "SecondDisplay.Host.Rust.exe"
#define TaskName "SecondDisplayHostRust"

#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif

#ifndef SourceDir
  #define SourceDir "..\build\staging-rust"
#endif

; Pass /DLangRu or /DLangEn for single-language installers; neither = multi-language.
#ifdef LangRu
  #define OutName "SecondDisplay-Rust-Setup-" + MyAppVersion + "-ru"
#else
  #ifdef LangEn
    #define OutName "SecondDisplay-Rust-Setup-" + MyAppVersion + "-en"
  #else
    #define OutName "SecondDisplay-Rust-Setup-" + MyAppVersion
  #endif
#endif

[Setup]
AppId={{F6C5B4A3-9E2D-4C1B-8A7F-0E9D8C7B6A54}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\releases
OutputBaseFilename={#OutName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName={#MyAppName} {#MyAppVersion}
CloseApplications=no
ShowLanguageDialog=yes

[Languages]
#ifdef LangRu
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
#else
  #ifdef LangEn
Name: "en"; MessagesFile: "compiler:Default.isl"
  #else
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"
  #endif
#endif

[CustomMessages]
#ifdef LangRu
AutostartTask=Запускать SecondDisplay (Rust) при входе в систему (нужны права администратора)
AutostartGroup=Автозапуск:
RunNow=Запустить SecondDisplay (Rust) сейчас
UninstallProgram=Удалить {#MyAppName}
#else
  #ifdef LangEn
AutostartTask=Start SecondDisplay (Rust) automatically at logon (requires administrator privileges)
AutostartGroup=Autostart:
RunNow=Start SecondDisplay (Rust) now
UninstallProgram=Uninstall {#MyAppName}
  #else
en.AutostartTask=Start SecondDisplay (Rust) automatically at logon (requires administrator privileges)
en.AutostartGroup=Autostart:
en.RunNow=Start SecondDisplay (Rust) now
en.UninstallProgram=Uninstall {#MyAppName}
ru.AutostartTask=Запускать SecondDisplay (Rust) при входе в систему (нужны права администратора)
ru.AutostartGroup=Автозапуск:
ru.RunNow=Запустить SecondDisplay (Rust) сейчас
ru.UninstallProgram=Удалить {#MyAppName}
  #endif
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "{cm:AutostartTask}"; GroupDescription: "{cm:AutostartGroup}"; Flags: checkedonce

[Files]
; Host executable and aliases
Source: "{#SourceDir}\host\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Bundled platform-tools (adb + dlls)
Source: "{#SourceDir}\platform-tools\*"; DestDir: "{app}\platform-tools"; Flags: ignoreversion
; Android client APK
Source: "{#SourceDir}\android\*"; DestDir: "{app}"; Flags: ignoreversion
; Setup helper script
Source: "{#SourceDir}\seconddisplay-setup.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#HostExeName}"; WorkingDir: "{app}"
Name: "{group}\{cm:UninstallProgram}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#HostExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#HostExeName}"; Parameters: "--auto"; Description: "{cm:RunNow}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\seconddisplay-setup.ps1"" -AppDir ""{app}"" -ExeName ""{#HostExeName}"" -TaskName ""{#TaskName}"" -UnregisterTask"; Flags: runhidden waituntilterminated; RunOnceId: "UnregTask"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\platform-tools"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  Params: String;
  ResultCode: Integer;
begin
  if CurStep = ssInstall then
  begin
    // Terminate any running host instance before copying new files
    Exec('powershell.exe', '-NoProfile -Command "Stop-Process -Name ''SecondDisplay.Host*'' -Force -ErrorAction SilentlyContinue"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;

  if CurStep = ssPostInstall then
  begin
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\seconddisplay-setup.ps1') +
              '" -AppDir "' + ExpandConstant('{app}') + '" -ExeName "{#HostExeName}" -TaskName "{#TaskName}"';
    if WizardIsTaskSelected('autostart') then
      Params := Params + ' -RegisterTask';
    Params := Params + ' -PushApk';

    if Exec('powershell.exe', Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    begin
      if ResultCode = 2 then
        MsgBox('Хост установлен, но приложение НЕ удалось поставить на планшет.' + #13#10 + #13#10 +
               'Подключите планшет по USB, включите «Отладку по USB» и подтвердите запрос на планшете, ' +
               'затем повторите установку клиента командой:' + #13#10 +
               '"' + ExpandConstant('{app}\seconddisplay-setup.ps1') + '" -AppDir "' + ExpandConstant('{app}') + '" -PushApk',
               mbInformation, MB_OK);
      if ResultCode = 1 then
        MsgBox('Не удалось зарегистрировать автозапуск (нужны права администратора).', mbError, MB_OK);
    end
    else
      MsgBox('Не удалось выполнить пост-установку (seconddisplay-setup.ps1).', mbError, MB_OK);
  end;
end;
