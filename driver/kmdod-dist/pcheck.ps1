$ErrorActionPreference='SilentlyContinue'
$p = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\KDODSamp' -Name Progress).Progress
"PROGRESS = $p"
$d = Get-PnpDevice -InstanceId 'ROOT\DEVGEN\SECONDDOD'
"STATUS   = " + $d.Status + " / " + $d.Problem
"=== Display adapters ==="
Get-PnpDevice -Class Display | ForEach-Object { "  " + $_.FriendlyName + " => " + $_.Status }
"=== Screens ==="
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "  " + $_.DeviceName + " " + $_.Bounds.Width + "x" + $_.Bounds.Height }
