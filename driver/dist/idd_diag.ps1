$ErrorActionPreference='SilentlyContinue'
wevtutil sl "Microsoft-Windows-DriverFrameworks-UserMode/Operational" /e:true | Out-Null
$ps = Get-PnpDeviceProperty -InstanceId 'ROOT\DEVGEN\SECONDIDD' -KeyName 'DEVPKEY_Device_ProblemStatus'
"ProblemStatus = 0x{0:X8}" -f ([uint32]$ps.Data)
"--- re-trigger ---"
Disable-PnpDevice -InstanceId 'ROOT\DEVGEN\SECONDIDD' -Confirm:$false
Start-Sleep 2
Enable-PnpDevice -InstanceId 'ROOT\DEVGEN\SECONDIDD' -Confirm:$false
Start-Sleep 4
"=== WUDF operational (last 8) ==="
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 8 | ForEach-Object { "  " + $_.TimeCreated.ToString('HH:mm:ss') + " id=" + $_.Id + ": " + (($_.Message -replace '\s+',' ')).Substring(0,[Math]::Min(160,$_.Message.Length)) }
"=== Kernel-PnP cfg for SECONDIDD ==="
Get-WinEvent -LogName 'Microsoft-Windows-Kernel-PnP/Configuration' -MaxEvents 40 | Where-Object { $_.Message -match 'SECONDIDD' } | Select-Object -First 2 | ForEach-Object { "  id=" + $_.Id + ": " + (($_.Message -replace '\s+',' ')).Substring(0,[Math]::Min(220,$_.Message.Length)) }
