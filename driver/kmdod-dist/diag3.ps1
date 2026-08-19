$ErrorActionPreference='SilentlyContinue'
$ps = Get-PnpDeviceProperty -InstanceId 'ROOT\DEVGEN\SECONDDOD' -KeyName 'DEVPKEY_Device_ProblemStatus'
"ProblemStatus = 0x{0:X8}" -f ([uint32]$ps.Data)
"=== Kernel-PnP/Configuration (SECONDDOD) ==="
Get-WinEvent -LogName 'Microsoft-Windows-Kernel-PnP/Configuration' -MaxEvents 60 | Where-Object { $_.Message -match 'SECONDDOD' } | Select-Object -First 4 Id, @{N='M';E={($_.Message -replace '\s+',' ')}} | Format-List
"=== DxgKrnl logs (all, last 30 min) ==="
foreach ($ln in 'Microsoft-Windows-DxgKrnl-Admin','Microsoft-Windows-DxgKrnl-Operational','Microsoft-Windows-DxgKrnl-Diagnostic') {
  $e = Get-WinEvent -LogName $ln -MaxEvents 10 -EA SilentlyContinue
  "  [$ln] events: " + ($e | Measure-Object).Count
  $e | Select-Object -First 4 | ForEach-Object { "    " + $_.Id + ": " + (($_.Message -replace '\s+',' ')).Substring(0,[Math]::Min(160,$_.Message.Length)) }
}
"=== System errors w/ display keywords (last 20 min) ==="
Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2,3; StartTime=(Get-Date).AddMinutes(-20)} -EA SilentlyContinue | Where-Object { $_.Message -match 'dxgk|Display|Grafik|Graphics|SECONDDOD|KDOD' } | Select-Object -First 6 Id,ProviderName,@{N='M';E={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(160,$_.Message.Length))}} | Format-List
