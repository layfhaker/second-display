@echo off
REM Build SecondDisplayIdd (IddCx UMDF driver) via EWDK.
REM Version config lives in SecondDisplayIdd.vcxproj (UMDF) + .inf (UmdfLibraryVersion/UmdfExtensions).
setlocal
set "PATH=C:\Program Files (x86)\Microsoft Visual Studio\Installer;%PATH%"
call D:\BuildEnv\SetupBuildEnv.cmd amd64
if errorlevel 1 (echo SetupBuildEnv FAILED & exit /b 1)
msbuild "%~dp0SecondDisplayIdd\SecondDisplayIdd.vcxproj" /p:Configuration=Release /p:Platform=x64 /v:minimal
exit /b %errorlevel%
