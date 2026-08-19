@echo off
echo === SecondDisplay: einmalige Admin-Einrichtung im Gast ===
echo.
echo [1/4] UAC-Token-Filter aus (damit guestcontrol Admin-Rechte bekommt)...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f
echo [2/4] Testsigning an...
bcdedit /set testsigning on
echo [3/4] Test-Zertifikat vertrauen (root)...
certutil -addstore -f root "C:\kmdod-dist\SampleDisplay.cer"
echo [4/4] Test-Zertifikat vertrauen (trustedpublisher)...
certutil -addstore -f trustedpublisher "C:\kmdod-dist\SampleDisplay.cer"
echo DONE > C:\kmdod-dist\_setup_done.txt
echo.
echo ====== FERTIG. Sag dem Host "fertig" - er macht den Rest. ======
pause
