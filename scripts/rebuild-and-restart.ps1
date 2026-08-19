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

Write-Host "Stopping scheduled task and killing running process..."
Stop-ScheduledTask -TaskName "SecondDisplayHost" -ErrorAction SilentlyContinue
Get-Process -Name "SecondDisplay.Host" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 1

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$hostProj = Join-Path $repoRoot 'host\SecondDisplay.Host\SecondDisplay.Host.csproj'

Write-Host "Rebuilding host in Release..."
& dotnet build "$hostProj" -c Release
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed with exit code $LASTEXITCODE" -ForegroundColor Red
    pause
    exit 1
}

Write-Host "Starting SecondDisplayHost task..."
Start-ScheduledTask -TaskName "SecondDisplayHost" -ErrorAction SilentlyContinue

Write-Host "SUCCESS! SecondDisplayHost rebuilt and restarted." -ForegroundColor Green
Start-Sleep -Seconds 2
