@echo off
set "PATH=C:\Program Files (x86)\Microsoft Visual Studio\Installer;%PATH%"
call D:\BuildEnv\SetupBuildEnv.cmd amd64 >nul 2>&1
set > "%TEMP%\ewdk_env.txt"
