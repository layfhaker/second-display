<#
  Watches what Windows does to its windows, so an unexplained "my window minimised itself when I
  clicked it" can be attributed after the fact.

  Every change of a window's minimised state is logged with the time, the window title, its process
  and where the mouse cursor was at that moment - so the next occurrence says who did it and whether
  the cursor was even over that window.

  Log: %LOCALAPPDATA%\SecondDisplay\window-events.log

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\watch-window-events.ps1
    # ...reproduce the problem, then look at the log...
#>
param(
    [string]$Log = "$env:LOCALAPPDATA\SecondDisplay\window-events.log",
    [int]$IntervalMs = 200
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path (Split-Path $Log) | Out-Null
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace SdWatch -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
'@

function Write-Line([string]$text) {
    try { Add-Content -Path $Log -Value $text -Encoding utf8 } catch { }
}

Write-Line ("--- watcher started " + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " ---")

$state = @{}
while ($true) {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $fg = [SdWatch.Win]::GetForegroundWindow().ToInt64()

    foreach ($p in Get-Process -ErrorAction SilentlyContinue) {
        $h = $p.MainWindowHandle
        if ($h -eq 0 -or -not $p.MainWindowTitle) { continue }
        $iconic = [SdWatch.Win]::IsIconic($h)
        $prev = $state[$p.Id]
        if ($null -eq $prev) { $state[$p.Id] = $iconic; continue }
        if ($prev -ne $iconic) {
            $state[$p.Id] = $iconic
            $what = if ($iconic) { 'MINIMIZED' } else { 'RESTORED ' }
            Write-Line ("{0:HH:mm:ss.fff} {1} pid={2,-6} cursor={3},{4} fg={5} title={6}" -f `
                (Get-Date), $what, $p.Id, $cursor.X, $cursor.Y, $fg, $p.MainWindowTitle)
        }
    }
    Start-Sleep -Milliseconds $IntervalMs
}
