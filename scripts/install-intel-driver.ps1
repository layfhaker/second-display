$ErrorActionPreference = "Continue"
$log = "C:\Users\admin\Documents\second display\tmp-build\install-log.txt"
"START $(Get-Date -Format o)" | Out-File $log
"User: $env:USERNAME | Admin: $([bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)))" | Out-File $log -Append

"Stopping host..." | Out-File $log -Append
Stop-Process -Name "SecondDisplay.Host" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
"Host alive after stop: $([bool](Get-Process -Name 'SecondDisplay.Host' -ErrorAction SilentlyContinue))" | Out-File $log -Append

"Disabling VDD..." | Out-File $log -Append
$vdd = Get-PnpDevice -FriendlyName 'Virtual Display Driver' -ErrorAction SilentlyContinue
if ($vdd) { Disable-PnpDevice -InstanceId $vdd.InstanceId -Confirm:$false; "VDD disabled" | Out-File $log -Append } else { "VDD not found" | Out-File $log -Append }
Start-Sleep -Seconds 2

"Running pnputil..." | Out-File $log -Append
pnputil /add-driver "C:\Users\admin\Downloads\Intel-Iris-Xe-32.0.101.7085\iigd_dch.inf" /install 2>&1 | Out-File $log -Append

"Driver now:" | Out-File $log -Append
(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -like '*Intel*' } | Select-Object DriverVersion) | Out-File $log -Append
"DONE $(Get-Date -Format o)" | Out-File $log -Append
