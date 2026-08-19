$ErrorActionPreference='SilentlyContinue'
wevtutil sl "Microsoft-Windows-DriverFrameworks-UserMode/Operational" /e:true | Out-Null
Disable-PnpDevice -InstanceId 'ROOT\DEVGEN\SECONDIDD' -Confirm:$false
Start-Sleep 2
Enable-PnpDevice -InstanceId 'ROOT\DEVGEN\SECONDIDD' -Confirm:$false
Start-Sleep 6
$d = Get-PnpDevice -InstanceId 'ROOT\DEVGEN\SECONDIDD'
"DEVICE  : '" + $d.FriendlyName + "'  Class=" + $d.Class
"STATUS  : " + $d.Status + " / " + $d.Problem
"=== ALL display+monitor devices ==="
Get-PnpDevice | Where-Object { $_.Class -in 'Display','Monitor' } | ForEach-Object { "  [" + $_.Class + "] " + $_.FriendlyName + " => " + $_.Status }
"=== Screens ==="
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "  " + $_.DeviceName + " " + $_.Bounds.Width + "x" + $_.Bounds.Height }
"=== FRESH WUDF (last 90 sec) ==="
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 20 | Where-Object { $_.TimeCreated -gt (Get-Date).AddSeconds(-90) } | Sort-Object TimeCreated | ForEach-Object { "  " + $_.TimeCreated.ToString('HH:mm:ss') + " id=" + $_.Id + ": " + (($_.Message -replace '\s+',' ')).Substring(0,[Math]::Min(95,$_.Message.Length)) }
