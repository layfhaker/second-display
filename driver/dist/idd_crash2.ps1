$ErrorActionPreference = 'SilentlyContinue'
$o = 'C:\idd-dist\crash2.txt'
$inst = 'ROOT\DEVGEN\{D1500775-3128-3D41-B707-C30E6983A65F}'
"=== CRASH2 $(Get-Date -Format o) ===" | Out-File $o -Encoding utf8
function L($m){ ($m | Out-String).TrimEnd() | Out-File $o -Append -Encoding utf8 }

# enable WUDF operational log just in case
wevtutil sl "Microsoft-Windows-DriverFrameworks-UserMode/Operational" /e:true 2>&1 | Out-Null

L "--- force retry: disable/enable ---"
Disable-PnpDevice -InstanceId $inst -Confirm:$false
Start-Sleep 3
Enable-PnpDevice -InstanceId $inst -Confirm:$false
Start-Sleep 15

$d = Get-PnpDevice -InstanceId $inst
L ("  Status=" + $d.Status + " Problem=" + $d.Problem)
$ps = (Get-PnpDeviceProperty -InstanceId $inst -KeyName 'DEVPKEY_Device_ProblemStatus').Data
L ("  ProblemStatus=" + $ps + ("  (0x{0:X8})" -f [int64]$ps))

L "--- ALL WUDF events (last 2 min) ---"
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 80 |
  Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-2) } | Sort-Object TimeCreated |
  ForEach-Object { L ("  " + $_.TimeCreated.ToString('HH:mm:ss') + " id=" + $_.Id + " " + (($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(150,$_.Message.Length)))) }

L "--- System log: WUDFRd/UMDF errors (last 3 min) ---"
Get-WinEvent -LogName System -MaxEvents 100 |
  Where-Object { $_.TimeCreated -gt (Get-Date).AddMinutes(-3) -and ($_.ProviderName -match 'WUDF|UMDF|Kernel-PnP' ) -and $_.LevelDisplayName -in 'Error','Warning' } | Sort-Object TimeCreated |
  ForEach-Object { L ("  " + $_.TimeCreated.ToString('HH:mm:ss') + " " + $_.ProviderName + " id=" + $_.Id + ": " + (($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(160,$_.Message.Length)))) }

L "--- newest WER reports (look for WUDFHost/SecondDisplayIdd) ---"
Get-ChildItem 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive','C:\ProgramData\Microsoft\Windows\WER\ReportQueue' -Recurse -Filter 'Report.wer' -EA SilentlyContinue |
  Sort-Object LastWriteTime -Desc | Select-Object -First 4 |
  ForEach-Object {
    $c = Get-Content $_.FullName
    if ($c -match 'WUDFHost|SecondDisplay|IddCx') {
      L ("--- " + $_.FullName + " ---")
      $c | Select-String 'AppName|ModName|ModVer|Exception|Offset|Sig\[|Value=' | Select-Object -First 16 | ForEach-Object { L ("    " + $_) }
    }
  }
L "=== END ==="
