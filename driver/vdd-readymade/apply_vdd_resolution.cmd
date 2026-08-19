@echo off
REM ============================================================
REM  Set the Virtual Display Driver to 3392x2400 (OPPO Pad 3 Pro, 3:2)
REM  Run AS ADMINISTRATOR (right-click -> Run as administrator).
REM ============================================================
setlocal
set "SRC=%~dp0vdd_settings.xml"
set "DST=C:\VirtualDisplayDriver\vdd_settings.xml"

echo === Backing up current config ===
if exist "%DST%" copy /y "%DST%" "%DST%.bak" >nul

echo === Writing new config (adds 3392x2400) ===
copy /y "%SRC%" "%DST%"
if errorlevel 1 (echo FAILED to write config & pause & exit /b 1)

echo === Restarting the virtual display to apply ===
powershell -NoProfile -Command "$d = Get-PnpDevice -FriendlyName 'Virtual Display Driver' -ErrorAction SilentlyContinue; if ($d) { Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false; Start-Sleep 2; Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false; Start-Sleep 3; Write-Host ('Status: ' + (Get-PnpDevice -InstanceId $d.InstanceId).Status) } else { Write-Host 'VDD device not found' }"

echo.
echo === Done. Check Settings -> Display: the virtual screen should now offer 3392x2400. ===
echo If it didn't switch automatically, set it manually in Display settings.
pause
