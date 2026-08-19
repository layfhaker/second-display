$ErrorActionPreference = 'SilentlyContinue'
$o = 'C:\idd-dist\rm_log.txt'
$rm = 'C:\idd-dist\rm'
$hwid = 'Root\MttVDD'
"=== READY-MADE VDD install $(Get-Date -Format o) ===" | Out-File $o -Encoding utf8
function L($m){ ($m | Out-String).TrimEnd() | Out-File $o -Append -Encoding utf8 }

# config file at the path MttVDD expects
New-Item -ItemType Directory -Force 'C:\VirtualDisplayDriver' | Out-Null
Copy-Item "$rm\vdd_settings.xml" 'C:\VirtualDisplayDriver\vdd_settings.xml' -Force
L "config placed at C:\VirtualDisplayDriver\vdd_settings.xml"

L "--- add-driver /install ---"
(pnputil /add-driver "$rm\MttVDD.inf" /install 2>&1) | ForEach-Object { L $_ }

L "--- create device ---"
(& 'C:\idd-dist\devgen.exe' /add /bus ROOT /hardwareid $hwid 2>&1) | ForEach-Object { L $_ }
Start-Sleep 2
# bind to present device (install order fix)
L "--- re-install onto present device ---"
(pnputil /add-driver "$rm\MttVDD.inf" /install 2>&1) | Select-Object -Last 4 | ForEach-Object { L $_ }

L "--- WAIT + RESULT ---"
for ($i=0; $i -lt 8; $i++) {
  Start-Sleep 4
  $d = Get-PnpDevice | Where-Object { $_.InstanceId -like 'ROOT\DEVGEN\*' -or $_.FriendlyName -like '*Virtual Display*' } | Select-Object -First 1
  L ("  t+{0,2}s  '{1}'  Status={2} Problem={3}" -f (($i+1)*4), $d.FriendlyName, $d.Status, $d.Problem)
  if ($d.Status -eq 'OK' -and $d.Problem -eq 'CM_PROB_NONE') { break }
}
Add-Type -AssemblyName System.Windows.Forms
L "--- Screens ---"
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { L ("  " + $_.DeviceName + " " + $_.Bounds.Width + "x" + $_.Bounds.Height + " primary=" + $_.Primary) }
L "--- Display adapters ---"
Get-PnpDevice -Class Display | ForEach-Object { L ("  " + $_.FriendlyName + " Status=" + $_.Status + " Problem=" + $_.Problem) }
L "--- WUDF (last 90s) ---"
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 40 |
  Where-Object { $_.TimeCreated -gt (Get-Date).AddSeconds(-90) -and $_.Id -in 2010,2007,4000 } | Sort-Object TimeCreated |
  ForEach-Object { L ("  " + $_.TimeCreated.ToString('HH:mm:ss') + " id=" + $_.Id + " " + (($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(90,$_.Message.Length)))) }
"=== DONE ===" | Out-File $o -Append -Encoding utf8
