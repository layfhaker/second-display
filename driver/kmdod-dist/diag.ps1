$ErrorActionPreference = 'SilentlyContinue'
$id = 'ROOT\DEVGEN\SECONDDOD'
$p = Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_ProblemCode','DEVPKEY_Device_ProblemStatus'
foreach ($x in $p) { "{0} = {1} (0x{2:X8})" -f $x.KeyName,$x.Data,([uint32]$x.Data) }
"=== System log: Display/dxgkrnl/BugCheck (last 30 min) ==="
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddMinutes(-30)} |
  Where-Object { $_.ProviderName -match 'Display|dxgkrnl|Kernel-PnP|BugCheck|KDOD|SecondDisplay' -or $_.Message -match 'KDOD|SecondDisplay|display|0x' } |
  Select-Object -First 12 TimeCreated, Id, ProviderName, @{N='Msg';E={ ($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(220,$_.Message.Length)) }} |
  Format-List
