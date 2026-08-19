$ErrorActionPreference = 'SilentlyContinue'
$o = 'C:\idd-dist\diag2.txt'
"=== DIAG2 $(Get-Date -Format o) ===" | Out-File $o -Encoding utf8
function L($m){ ($m | Out-String).TrimEnd() | Out-File $o -Append -Encoding utf8 }

L "--- our device(s) by hardware id Root\SecondDisplayIdd ---"
$devs = Get-PnpDevice | Where-Object { $_.InstanceId -like 'ROOT\DEVGEN\*' -or $_.HardwareID -contains 'Root\SecondDisplayIdd' -or $_.FriendlyName -like '*SecondDisplay*' }
foreach ($d in $devs) {
  L ("  InstanceId : " + $d.InstanceId)
  L ("  Friendly   : " + $d.FriendlyName)
  L ("  Class      : " + $d.Class + "   Status=" + $d.Status + "  Problem=" + $d.Problem)
  $svc = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_Service').Data
  $inf = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath').Data
  $pst = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemStatus').Data
  L ("  Service=" + $svc + "  Inf=" + $inf + "  ProblemStatus=" + $pst)
  L ""
}

L "--- Display adapters ---"
Get-PnpDevice -Class Display | ForEach-Object { L ("  " + $_.FriendlyName + "  Status=" + $_.Status + " Problem=" + $_.Problem) }

L "--- Monitors ---"
Get-PnpDevice -Class Monitor | ForEach-Object { L ("  " + $_.FriendlyName + "  Status=" + $_.Status) }

L "--- Screens ---"
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { L ("  " + $_.DeviceName + " " + $_.Bounds.Width + "x" + $_.Bounds.Height + " primary=" + $_.Primary) }

L "--- WUDF events (last 5 min): 2010=loaded 2007/4000=fail ---"
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 60 |
  Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-5) -and $_.Id -in 2010,2007,4000,10110,10111 } | Sort-Object TimeCreated |
  ForEach-Object { L ("  " + $_.TimeCreated.ToString('HH:mm:ss') + " id=" + $_.Id + ": " + (($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(180,$_.Message.Length)))) }

L "=== END ==="
