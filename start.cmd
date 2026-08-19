@echo off
title SecondDisplay Host + ADB

set PORT=27315
set HOST_DIR=%~dp0host\SecondDisplay.Host\bin\Release\net8.0-windows
set HOST_EXE=%HOST_DIR%\SecondDisplay.Host.exe
set HOST_ARGS=

if not exist "%HOST_EXE%" (
    echo [!] Host not built. Building...
    dotnet build "%~dp0host\SecondDisplay.Host\SecondDisplay.Host.csproj" -c Release
    if errorlevel 1 (
        echo [ERROR] Build failed.
        pause
        exit /b 1
    )
)

where adb >nul 2>&1
if errorlevel 1 (
    echo [ERROR] adb not found in PATH.
    pause
    exit /b 1
)

echo  Restarting adb server...
taskkill /IM adb.exe /F >nul 2>&1
adb start-server >nul 2>&1

echo.
echo  SecondDisplay
echo  ================================================
echo.
echo  1) Mirror primary display
echo  2) Extend (use second monitor)
echo.
set /p MODE="  Choose [1/2]: "

if not "%MODE%"=="2" goto :do_adb

echo.
echo  Detecting monitors...
powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $i = [array]::IndexOf([System.Windows.Forms.Screen]::AllScreens, $_); Write-Host ('    [' + $i + '] ' + $_.DeviceName + '  ' + $_.Bounds.Width + 'x' + $_.Bounds.Height + $(if($_.Primary){' PRIMARY'} else {''})) }"
echo.
set /p DISPIDX="  Monitor index: "
set HOST_ARGS=--display %DISPIDX%

:do_adb
echo.
echo  Connected devices:
adb devices
echo.
echo  Setting up adb reverse tcp:%PORT%...
adb reverse tcp:%PORT% tcp:%PORT%
if errorlevel 1 (
    echo  [ERROR] adb reverse failed. Check USB.
    pause
    exit /b 1
)
echo  [OK] Port forwarded.
echo.
echo  Going headless...

REM Build a hidden runner: runs the host, then removes the port forward on exit.
> "%~dp0_run_host.cmd" echo @echo off
>> "%~dp0_run_host.cmd" echo "%HOST_EXE%" %HOST_ARGS%
>> "%~dp0_run_host.cmd" echo adb reverse --remove tcp:%PORT% ^>nul 2^>^&1
>> "%~dp0_run_host.cmd" echo del "%%~f0"

REM VBS launches the runner with a hidden window and does not wait.
> "%~dp0_hide.vbs" echo Set ws = CreateObject("WScript.Shell")
>> "%~dp0_hide.vbs" echo ws.Run "cmd /c ""%~dp0_run_host.cmd""", 0, False
>> "%~dp0_hide.vbs" echo Set fso = CreateObject("Scripting.FileSystemObject")
>> "%~dp0_hide.vbs" echo fso.DeleteFile WScript.ScriptFullName

start "" cscript //nologo "%~dp0_hide.vbs"
exit
