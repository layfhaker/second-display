$ErrorActionPreference='SilentlyContinue'
"=== bound driver/service on device ==="
$p = Get-PnpDeviceProperty -InstanceId 'ROOT\DEVGEN\SECONDIDD' -KeyName 'DEVPKEY_Device_Service','DEVPKEY_Device_ClassGuid','DEVPKEY_Device_DriverInfPath'
foreach ($x in $p) { "  " + $x.KeyName + " = " + $x.Data }
"=== force install onto present device ==="
$o = pnputil /add-driver C:\idd-dist\SecondDisplayIdd.inf /install 2>&1
$o | Select-Object -Last 5
Start-Sleep 8
"=== status after ==="
$d = Get-PnpDevice -InstanceId 'ROOT\DEVGEN\SECONDIDD'
"  '" + $d.FriendlyName + "' Class=" + $d.Class + " Status=" + $d.Status + "/" + $d.Problem
"=== screens ==="
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | %{ "  " + $_.DeviceName + " " + $_.Bounds.Width + "x" + $_.Bounds.Height }
"=== FRESH WUDF (last 60s) ==="
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 25 | ? { $_.TimeCreated -gt (Get-Date).AddSeconds(-60) } | sort TimeCreated | %{ "  " + $_.TimeCreated.ToString('HH:mm:ss') + " " + $_.Id + ": " + (($_.Message -replace '\s+',' ')).Substring(0,[Math]::Min(90,$_.Message.Length)) }
