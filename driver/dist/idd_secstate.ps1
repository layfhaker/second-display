$o = 'C:\idd-dist\secstate.txt'
$lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name EnableLUA -EA SilentlyContinue).EnableLUA
"EnableLUA=$lua" | Out-File $o -Encoding utf8
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
"IsElevated=$admin" | Out-File $o -Append -Encoding utf8
"build=" + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild | Out-File $o -Append -Encoding utf8
"UBR=" + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR | Out-File $o -Append -Encoding utf8
(bcdedit /enum '{current}') 2>&1 | Select-String 'testsigning|description' | ForEach-Object { $_.ToString() } | Out-File $o -Append -Encoding utf8
