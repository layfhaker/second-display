$ErrorActionPreference = 'SilentlyContinue'
$dist = 'C:\idd-dist'
$inf  = Join-Path $dist 'SecondDisplayIdd.inf'
$hwid = 'Root\SecondDisplayIdd'
$inst = 'ROOT\DEVGEN\SECONDIDD'

function devgen {
  $cand = @("$dist\devgen.exe","C:\Windows\System32\devgen.exe",
            "${env:ProgramFiles(x86)}\Windows Kits\10\Tools\10.0.28000.0\x64\devgen.exe")
  foreach ($c in $cand) { if (Test-Path $c) { return $c } }
  (Get-Command devgen.exe -EA SilentlyContinue).Source
}

"==================== CLEANUP ===================="
# 1) remove any existing virtual device(s)
Get-PnpDevice -InstanceId $inst -EA SilentlyContinue | ForEach-Object {
  "  removing device " + $_.InstanceId
  pnputil /remove-device $_.InstanceId 2>&1 | Out-Null
}
# 2) delete every DriverStore copy from our provider (kills oem*.inf dupes)
$drivers = pnputil /enum-drivers
$cur = $null
foreach ($ln in $drivers) {
  if ($ln -match 'Published Name\s*:\s*(oem\d+\.inf)') { $cur = $matches[1] }
  if ($ln -match 'Provider Name\s*:\s*(.+)' -and $cur) {
    if ($matches[1] -match 'SecondDisplay') {
      "  deleting DriverStore pkg $cur"
      pnputil /delete-driver $cur /uninstall /force 2>&1 | Out-Null
    }
    $cur = $null
  }
}
Start-Sleep 3

"==================== INSTALL ===================="
"  add-driver + install:"
(pnputil /add-driver $inf /install 2>&1) | Select-Object -Last 4
Start-Sleep 2
$dg = devgen
if (-not $dg) { "  !! devgen.exe NOT FOUND - cannot create device"; return }
"  devgen: $dg"
(& $dg /add /bus ROOT /hardwareid $hwid 2>&1) | Select-Object -Last 2

"==================== WAIT FOR LOAD ===================="
$loaded = $false
for ($i=0; $i -lt 12; $i++) {
  Start-Sleep 5
  $d = Get-PnpDevice -InstanceId $inst -EA SilentlyContinue
  $svc = (Get-PnpDeviceProperty -InstanceId $inst -KeyName 'DEVPKEY_Device_Service' -EA SilentlyContinue).Data
  "  t+{0,2}s  Status={1}/{2}  Service={3}" -f (($i+1)*5), $d.Status, $d.Problem, $svc
  $wudf = Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 5 -EA SilentlyContinue |
          Where-Object { $_.TimeCreated -gt (Get-Date).AddSeconds(-20) -and $_.Id -in 2010,2007,4000 }
  if ($wudf) { $loaded = $true; break }
}

"==================== RESULT ===================="
$d = Get-PnpDevice -InstanceId $inst -EA SilentlyContinue
"  Device : '" + $d.FriendlyName + "' Class=" + $d.Class + " Status=" + $d.Status + "/" + $d.Problem
Add-Type -AssemblyName System.Windows.Forms
"  Screens:"
[System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "    " + $_.DeviceName + " " + $_.Bounds.Width + "x" + $_.Bounds.Height + " primary=" + $_.Primary }

"  --- WUDF events (last 90s) ---"
Get-WinEvent -LogName 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' -MaxEvents 40 -EA SilentlyContinue |
  Where-Object { $_.TimeCreated -gt (Get-Date).AddSeconds(-90) } | Sort-Object TimeCreated |
  ForEach-Object { "    " + $_.TimeCreated.ToString('HH:mm:ss') + " id=" + $_.Id + ": " + (($_.Message -replace '\s+',' ').Substring(0,[Math]::Min(110,$_.Message.Length))) }

"  --- WER (if crashed) ---"
Get-ChildItem 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive','C:\ProgramData\Microsoft\Windows\WER\ReportQueue' -Recurse -Filter 'Report.wer' -EA SilentlyContinue |
  Sort-Object LastWriteTime -Desc | Select-Object -First 1 |
  ForEach-Object { Get-Content $_.FullName | Select-String 'AppName|ModName|ModVer|Exception|Offset|Sig\[' | Select-Object -First 10 | ForEach-Object { "    " + $_ } }
"==================== DONE ===================="
