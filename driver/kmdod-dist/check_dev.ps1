$ErrorActionPreference = 'SilentlyContinue'
$d = Get-PnpDevice -InstanceId 'ROOT\DEVGEN\SECONDDOD'
"DEVICE   : " + $d.FriendlyName
"CLASS    : " + $d.Class
"STATUS   : " + $d.Status
"PROBLEM  : " + $d.Problem + " " + $d.ProblemDescription
"=== Display adapters ==="
Get-PnpDevice -Class Display | ForEach-Object { "  " + $_.FriendlyName + "  =>  " + $_.Status }
"=== Monitors (WMI) count ==="
(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID | Measure-Object).Count
"=== Screens (from Windows) ==="
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "  " + $_.DeviceName + "  " + $_.Bounds.Width + "x" + $_.Bounds.Height }
