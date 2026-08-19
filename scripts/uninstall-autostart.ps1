<#
.SYNOPSIS
    Removes the SecondDisplayHost autostart scheduled task, and best-effort disables the
    virtual display driver so no phantom monitor is left behind.
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

$taskName = 'SecondDisplayHost'

try {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
    Write-Host "Scheduled task '$taskName' removed."
}
catch {
    Write-Host "Could not remove scheduled task '$taskName': $($_.Exception.Message)" -ForegroundColor Yellow
}

# Best-effort: leave no phantom monitor behind.
try {
    $dev = Get-PnpDevice -FriendlyName 'Virtual Display Driver' -ErrorAction SilentlyContinue
    if ($dev) {
        $dev | Disable-PnpDevice -Confirm:$false -ErrorAction Stop
        Write-Host "Virtual Display Driver disabled."
    }
}
catch {
    Write-Host "Could not disable Virtual Display Driver: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=================================================================="
Write-Host " SecondDisplayHost autostart uninstalled"
Write-Host "=================================================================="
