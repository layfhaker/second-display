<#
.SYNOPSIS
    Restarts the SecondDisplay host: stops the running instance, rebuilds it in Release
    and starts it again via the "SecondDisplayHost" scheduled task.

.DESCRIPTION
    Use after changing host code. Self-elevates (one UAC prompt) because the host runs
    with highest privileges (needed for the virtual display driver) and cannot be
    stopped from a non-elevated shell.
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

    Write-Host "Stopping SecondDisplay.Host..."
    Get-Process SecondDisplay.Host -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1

    Write-Host "Building host in Release: $hostProj"
    & dotnet build "$hostProj" -c Release
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet build failed with exit code $LASTEXITCODE"
    }

    Write-Host "Starting scheduled task 'SecondDisplayHost'..."
    Start-ScheduledTask -TaskName 'SecondDisplayHost'

    Write-Host ""
    Write-Host "Host restarted." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "RESTART FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
