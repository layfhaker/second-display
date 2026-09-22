<#
  SecondDisplay post-install helper (run elevated by the installer / uninstaller).

  Responsibilities:
    - register / unregister the "SecondDisplayHost" scheduled task: runs the auto host at logon
      in the interactive session with highest privileges (VDD enable/disable needs admin);
    - push (install) the Android client APK to the connected tablet over adb — mandatory during
      install: the app must end up on the tablet;
    - grant everything grantable without touching the screen (install -r -g, pm grant for
      runtime permissions, appops allow, accessibility settings put) and report what still
      needs one manual tap (USB debugging authorize dialog, accessibility toggle if blocked);
    - log everything to %LOCALAPPDATA%\SecondDisplay\install.log.

  Exit codes: 0 = ok, 1 = task registration failed, 2 = tablet/APK install failed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AppDir,
    [string]$Apk = '',
    [string]$ExeName = 'SecondDisplay.Host.exe',
    [string]$TaskName = 'SecondDisplayHost',
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

Log "=== SecondDisplay setup: AppDir='$AppDir' ExeName='$ExeName' TaskName='$TaskName' RegisterTask=$RegisterTask UnregisterTask=$UnregisterTask PushApk=$PushApk ==="

$Exe = Join-Path $AppDir $ExeName
if (-not (Test-Path $Exe)) {
    $alt = Join-Path $AppDir 'SecondDisplay.Host.exe'
    if (Test-Path $alt) { $Exe = $alt }
}

function Register-HostTask {
    if (-not (Test-Path $Exe)) { Log "ERROR: host exe not found: $Exe"; return 1 }
    try {
        $action = New-ScheduledTaskAction -Execute $Exe -Argument '--auto' -WorkingDirectory $AppDir
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        # RestartCount/RestartInterval matter: the host exits on its own when its commit passes a
        # safety limit (it leaks memory while streaming - being fixed), and nothing else would bring
        # it back, leaving the tablet black until the next logon.
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Log "scheduled task '$TaskName' registered (at logon, highest privileges)."
        return 0
    } catch {
        Log "ERROR registering task: $($_.Exception.Message)"
        return 1
    }
}

function Unregister-HostTask {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $procName = [System.IO.Path]::GetFileNameWithoutExtension($ExeName)
    Get-Process $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($procName -ne 'SecondDisplay.Host') {
        Get-Process SecondDisplay.Host -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
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

    $pkg = 'com.seconddisplay.client'
    $a11y = "$pkg/.ShortcutAccessibilityService"

    Log "adb: $adb"
    & $adb start-server 2>&1 | Out-Null

    # Fast fail with a helpful message when the tablet needs its one manual tap:
    # "unauthorized" means USB debugging is on but the RSA fingerprint dialog on the
    # tablet was not accepted yet — nothing automated can get past that by design.
    $states = @{}
    foreach ($line in (& $adb devices 2>&1)) {
        if ($line -match '^(\S+)\s+(\S+)\s*$') { $states[$Matches[1]] = $Matches[2] }
    }
    $serials = @($states.Keys | Where-Object { $states[$_] -eq 'device' })
    if ($serials.Count -eq 0) {
        if (@($states.Keys | Where-Object { $states[$_] -eq 'unauthorized' }).Count -gt 0) {
            Log "TABLET UNAUTHORIZED: the tablet is connected but its 'Allow USB debugging?' dialog was not accepted. Tap 'Allow' on the tablet, then re-run: `"$PSCommandPath`" -AppDir `"$AppDir`" -PushApk"
        } else {
            Log "NO TABLET: no adb device in 'device' state (connect the tablet, enable USB debugging, accept the prompt)."
        }
        return 2
    }

    $rc = 1
    foreach ($s in $serials) {
        Log "installing client APK on $s ..."
        # -r reinstall, -g grant all install-time permissions at once (no per-permission taps).
        # NOTE: -g covers install-time permissions only. Runtime permissions (POST_NOTIFICATIONS
        # etc.) still need `pm grant` per permission below, and the accessibility service needs
        # `settings put secure` — both are attempted right after install.
        $out = & $adb -s $s install -r -g "$apkPath" 2>&1
        Log ("  " + ($out -join " / "))
        if ($out -match 'Success') { $rc = 0 } else { continue }

        # Best-effort runtime grants: harmless when the permission does not exist on this
        # Android version, skipped silently per permission.
        foreach ($perm in @('android.permission.POST_NOTIFICATIONS', 'android.permission.READ_MEDIA_IMAGES', 'android.permission.READ_MEDIA_VIDEO')) {
            $g = & $adb -s $s shell pm grant $pkg $perm 2>&1
            if ($g -notmatch 'Unknown permission|does not declare|SecurityException|not a changeable permission|Bad argument') {
                Log ("  grant ${perm}: " + ($g -join " / "))
            }
        }
        $ao = & $adb -s $s shell appops set $pkg SYSTEM_ALERT_WINDOW allow 2>&1
        Log ("  appops SYSTEM_ALERT_WINDOW: " + ($ao -join " / "))

        # Accessibility (global hotkeys): enabled via settings, no screen tap needed on most
        # builds. Some OEMs ignore the put — then Grant-Accessibility returns a warning and the
        # user flips one toggle in Settings > Accessibility > SecondDisplay.
        $cur = (& $adb -s $s shell settings get secure enabled_accessibility_services 2>&1) -join ''
        if ($cur -notmatch [regex]::Escape($a11y)) {
            $new = if ($cur -match 'null|^\s*$') { $a11y } else { "$cur`:$a11y" }
            & $adb -s $s shell settings put secure enabled_accessibility_services "$new" 2>&1 | Out-Null
            & $adb -s $s shell settings put secure accessibility_enabled 1 2>&1 | Out-Null
        }
        $verify = (& $adb -s $s shell settings get secure enabled_accessibility_services 2>&1) -join ''
        if ($verify -match [regex]::Escape($a11y)) {
            Log "  accessibility service enabled."
        } else {
            Log "  WARNING: accessibility service NOT enabled (OEM blocked settings put). Enable manually: Settings > Accessibility > SecondDisplay > On."
        }

        # Wake the client so the user sees it working immediately.
        & $adb -s $s shell am start -n "$pkg/.MainActivity" 2>&1 | Out-Null
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
