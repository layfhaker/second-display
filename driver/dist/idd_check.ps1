$ErrorActionPreference='SilentlyContinue'
$d = Get-PnpDevice -InstanceId 'ROOT\DEVGEN\SECONDIDD'
"DEVICE  : " + $d.FriendlyName
"STATUS  : " + $d.Status + " / " + $d.Problem
"=== Display adapters ==="
Get-PnpDevice -Class Display | ForEach-Object { "  " + $_.FriendlyName + " => " + $_.Status }
"=== Monitors (Class) ==="
Get-PnpDevice -Class Monitor | ForEach-Object { "  " + $_.FriendlyName + " => " + $_.Status }
"=== Screens ==="
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "  " + $_.DeviceName + " " + $_.Bounds.Width + "x" + $_.Bounds.Height + " primary=" + $_.Primary }
"=== WUDF events (last 5) ==="
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 6 | ForEach-Object { "  " + $_.Id + ": " + (($_.Message -replace '\s+',' ')).Substring(0,[Math]::Min(110,$_.Message.Length)) }
