<#
  SecondDisplay post-install helper (run elevated by the installer / uninstaller).

  Responsibilities:
    - register / unregister the "SecondDisplayHost" scheduled task: runs the auto host at logon
      in the interactive session with highest privileges (VDD enable/disable needs admin);
    - push (install) the Android client APK to the connected tablet over adb — mandatory during
      install: the app must end up on the tablet;
    - log everything to %LOCALAPPDATA%\SecondDisplay\install.log.

  Exit codes: 0 = ok, 1 = task registration failed, 2 = tablet/APK install failed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [string]$Apk = '',
    [switch]$RegisterTask,
    [switch]$UnregisterTask,
    [switch]$PushApk
)

$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:LOCALAPPDATA 'SecondDisplay'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'install.log'

function Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    $line | Out-File -FilePath $log -Append -Encoding utf8
    Write-Host $line
}

Log "=== SecondDisplay setup: AppDir='$AppDir' RegisterTask=$RegisterTask UnregisterTask=$UnregisterTask PushApk=$PushApk ==="

$TaskName = 'SecondDisplayHost'
$Exe = Join-Path $AppDir 'SecondDisplay.Host.exe'

function Register-HostTask {
    if (-not (Test-Path $Exe)) { Log "ERROR: host exe not found: $Exe"; return 1 }
    try {
        $action = New-ScheduledTaskAction -Execute $Exe -Argument '--auto' -WorkingDirectory $AppDir
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Log "scheduled task '$TaskName' registered (at logon, highest privileges)."
        Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Log "task started."
        return 0
    } catch {
        Log "ERROR registering task: $($_.Exception.Message)"
        return 1
    }
}

function Unregister-HostTask {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-Process SecondDisplay.Host -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Log "scheduled task '$TaskName' removed."
    return 0
}

function Push-ClientApk {
    $adb = Join-Path $AppDir 'platform-tools\adb.exe'
    if (-not (Test-Path $adb)) { $adb = 'adb' }

    $apkPath = $Apk
    if ([string]::IsNullOrEmpty($apkPath)) {
        $apkPath = Get-ChildItem -Path $AppDir -Filter *.apk -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $apkPath -or -not (Test-Path $apkPath)) { Log "ERROR: client APK not found (looked in $AppDir)."; return 2 }

    Log "adb: $adb"
    & $adb start-server 2>&1 | Out-Null

    $serials = @()
    foreach ($line in (& $adb devices 2>&1)) {
        if ($line -match '^(\S+)\s+device\s*$') { $serials += $Matches[1] }
    }
    if ($serials.Count -eq 0) {
        Log "NO TABLET: no adb device in 'device' state (connect the tablet, enable USB debugging, accept the prompt)."
        return 2
    }

    $rc = 1
    foreach ($s in $serials) {
        Log "installing client APK on $s ..."
        $out = & $adb -s $s install -r "$apkPath" 2>&1
        Log ("  " + ($out -join " / "))
        if ($out -match 'Success') { $rc = 0 }
    }
    if ($rc -eq 0) { Log "client APK installed." } else { Log "client APK install FAILED." }
    return $rc
}

$rc = 0
if ($UnregisterTask) { Unregister-HostTask | Out-Null }
if ($RegisterTask)   { $t = Register-HostTask; if ($t -ne 0) { $rc = 1 } }
if ($PushApk)        { $p = Push-ClientApk;  if ($p -ne 0) { $rc = $p } }

Log "exit code: $rc"
exit $rc
