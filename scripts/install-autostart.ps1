<#
.SYNOPSIS
    Builds the SecondDisplay host in Release and registers it as a Task Scheduler job that
    starts hidden, at logon, with highest privileges (needed for Enable/Disable-PnpDevice on
    the virtual display driver).

.DESCRIPTION
    Run this once per machine. It self-elevates (one UAC prompt), builds
    host/SecondDisplay.Host in Release, and registers a scheduled task named
    "SecondDisplayHost" that launches "SecondDisplay.Host.exe --auto" hidden at user logon.
#>

$ErrorActionPreference = 'Stop'

# --- Self-elevate -----------------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting administrator privileges..."
    $scriptPath = $MyInvocation.MyCommand.Path
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") `
        -Verb RunAs
    exit
}

try {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
    $hostProj = Join-Path $repoRoot 'host\SecondDisplay.Host\SecondDisplay.Host.csproj'
    if (-not (Test-Path $hostProj)) {
        throw "Host project not found at: $hostProj"
    }

    Write-Host "Building host in Release: $hostProj"
    & dotnet build "$hostProj" -c Release
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE"
    }

    $exePath = Join-Path $repoRoot 'host\SecondDisplay.Host\bin\Release\net8.0-windows\SecondDisplay.Host.exe'
    if (-not (Test-Path $exePath)) {
        throw "Build succeeded but exe not found at: $exePath"
    }
    Write-Host "Host exe: $exePath"

    $taskName = 'SecondDisplayHost'
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -RunLevel Highest `
        -LogonType Interactive

    # Run via a hidden PowerShell wrapper so no console window flashes up at logon.
    $wrapperArgs = "-NoProfile -WindowStyle Hidden -Command `"Start-Process -FilePath '$exePath' -ArgumentList '--auto' -WindowStyle Hidden`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $wrapperArgs

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)

    Write-Host "Registering scheduled task '$taskName'..."
    Register-ScheduledTask -TaskName $taskName `
        -Trigger $trigger `
        -Action $action `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    $logPath = Join-Path $env:LOCALAPPDATA 'SecondDisplay\host.log'

    Write-Host ""
    Write-Host "=================================================================="
    Write-Host " SecondDisplayHost autostart installed"
    Write-Host "=================================================================="
    Write-Host " Task name     : $taskName"
    Write-Host " Runs          : at logon, highest privileges (needed for VDD control)"
    Write-Host " Executable    : $exePath --auto"
    Write-Host " Log file      : $logPath"
    Write-Host ""
    Write-Host " You do not need to reboot to try it now:"
    Write-Host "   Start-ScheduledTask -TaskName $taskName"
    Write-Host "=================================================================="
}
catch {
    Write-Host ""
    Write-Host "INSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
