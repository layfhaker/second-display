; SecondDisplay installer (Inno Setup 6).
; Build it with scripts\build-release.ps1, which passes /DMyAppVersion and /DSourceDir.
;
; What it does:
;   - installs the host into %ProgramFiles%\SecondDisplay (64-bit);
;   - bundles the Android client APK and platform-tools (adb);
;   - registers the SecondDisplayHost autostart scheduled task (elevated, interactive session);
;   - pushes the client APK to the connected tablet over adb (mandatory step during install);
;   - the host writes its runtime log to %LOCALAPPDATA%\SecondDisplay\host.log.

#define MyAppName "SecondDisplay"
#define MyAppPublisher "SecondDisplay"
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\staging"
#endif
; Pass /DLangRu or /DLangEn for single-language installers; neither = multi-language.
#ifdef LangRu
  #define OutName "SecondDisplay-Setup-" + MyAppVersion + "-ru"
#else
  #ifdef LangEn
    #define OutName "SecondDisplay-Setup-" + MyAppVersion + "-en"
  #else
    #define OutName "SecondDisplay-Setup-" + MyAppVersion
  #endif
#endif

[Setup]
AppId={{B7E2A9C4-1D3F-4E7A-9C21-5F8D2B6A0E13}
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
InfoBeforeFile=
; The host is a signed-by-nobody personal build; keep it simple, no restart prompt.
CloseApplications=no

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

[Tasks]
Name: "autostart"; Description: "Запускать SecondDisplay при входе в систему (нужны права администратора)"; GroupDescription: "Автозапуск:"; Flags: checkedonce

[Files]
; Host publish output (exe + deps + runtimes).
Source: "{#SourceDir}\host\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Bundled adb so the installed host (and this installer) do not depend on the user's PATH.
Source: "{#SourceDir}\platform-tools\*"; DestDir: "{app}\platform-tools"; Flags: ignoreversion
; Android client to push to the tablet.
Source: "{#SourceDir}\android\*"; DestDir: "{app}"; Flags: ignoreversion
; Post-install / uninstall helper.
Source: "{#SourceDir}\seconddisplay-setup.ps1"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\SecondDisplay (вручную, зеркало)"; Filename: "{app}\SecondDisplay.Host.exe"; Parameters: "--fps 30"; WorkingDir: "{app}"
Name: "{group}\Удалить {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
; Register the autostart task + push the APK. Done in [Code] so we can react to the result.
Filename: "{app}\SecondDisplay.Host.exe"; Description: "Запустить SecondDisplay сейчас"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\seconddisplay-setup.ps1"" -AppDir ""{app}"" -UnregisterTask"; Flags: runhidden waituntilterminated; RunOnceId: "UnregTask"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\platform-tools"

[Code]
procedure CurStepChanged(CurStep: TSetupStep);
var
  Params: String;
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    Params := '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\seconddisplay-setup.ps1') +
              '" -AppDir "' + ExpandConstant('{app}') + '"';
    if WizardIsTaskSelected('autostart') then
      Params := Params + ' -RegisterTask';
    Params := Params + ' -PushApk';

    if Exec('powershell.exe', Params, '', SW_SHOW, ewWaitUntilTerminated, ResultCode) then
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
