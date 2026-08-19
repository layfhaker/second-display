$ErrorActionPreference = 'SilentlyContinue'
"=== Kernel-PnP/Configuration for SECONDDOD ==="
Get-WinEvent -LogName 'Microsoft-Windows-Kernel-PnP/Configuration' -MaxEvents 40 |
  Where-Object { $_.Message -match 'SECONDDOD' } |
  Select-Object -First 6 TimeCreated, Id, @{N='Msg';E={($_.Message -replace '\s+',' ')}} | Format-List
"=== DxgKrnl Admin (errors) ==="
Get-WinEvent -LogName 'Microsoft-Windows-DxgKrnl-Admin' -MaxEvents 20 |
  Select-Object -First 8 TimeCreated, Id, LevelDisplayName, @{N='Msg';E={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(200,$_.Message.Length))}} | Format-List
"=== App log: KDODSamp / SampleDisplay source ==="
Get-WinEvent -LogName 'System' -MaxEvents 60 |
  Where-Object { $_.ProviderName -match 'KDOD|SampleDisplay|Display' -or $_.Message -match 'KDOD|SampleDisplay' } |
  Select-Object -First 6 TimeCreated, Id, ProviderName, @{N='Msg';E={($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(200,$_.Message.Length))}} | Format-List
