@echo off
echo === Montiere sauberes Windows-Image (read-only) ===
if not exist C:\wimmnt mkdir C:\wimmnt
dism /Mount-Wim /WimFile:E:\sources\install.wim /Index:1 /MountDir:C:\wimmnt /ReadOnly
echo.
echo === fertig. Sag dem Host "смонтировал". ===
pause
