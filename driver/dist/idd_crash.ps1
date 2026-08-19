$ErrorActionPreference='SilentlyContinue'
"=== WUDF 4000 (full) ==="
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 15 | Where-Object Id -eq 4000 | Select-Object -First 1 | ForEach-Object { $_.Message -replace '\s+',' ' }
"=== Application APPCRASH (WUDFHost) ==="
Get-WinEvent -LogName 'Application' -MaxEvents 200 | Where-Object { $_.Message -match 'WUDFHost|SecondDisplayIdd' } | Select-Object -First 3 | ForEach-Object { "--- id=" + $_.Id + " ---"; ($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(500,$_.Message.Length)) }
"=== WER reports on disk ==="
Get-ChildItem 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive','C:\ProgramData\Microsoft\Windows\WER\ReportQueue' -Recurse -Filter 'Report.wer' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 2 | ForEach-Object { "--- " + $_.FullName + " ---"; Get-Content $_.FullName | Select-String 'AppName|Mod(Name|Ver)|Exception|Offset|Sig\[' | Select-Object -First 12 }
