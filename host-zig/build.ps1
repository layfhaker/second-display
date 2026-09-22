# SecondDisplay Zig host build (zig build-exe, no build.zig - stable CLI).
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $root
try {
    $zig = $null
    foreach ($cand in @(
        "$env:LOCALAPPDATA\zig\zig.exe",
        "$env:USERPROFILE\_devhome\zig14\zig-x86_64-windows-0.14.1\zig.exe",
        "$env:USERPROFILE\_devhome\zig14\zig-lib-parent.exe",
        "$env:USERPROFILE\_devhome\zig14\zig.exe",
        "$env:USERPROFILE\_devhome\zig\zig-x86_64-windows-0.16.0\zig.exe",
        "$env:USERPROFILE\_devhome\zig\zig.exe",
        "zig.exe"
    )) {
        if ($cand -eq "zig.exe") { $zig = "zig.exe"; break }
        if (Test-Path $cand) { $zig = $cand; break }
    }
    if (-not $zig) { throw "zig compiler not found" }

    $out = Join-Path $root "bin"
    New-Item -ItemType Directory -Force -Path $out | Out-Null
    $bin = Join-Path $out "seconddisplay-host-zig.exe"

    & $zig build-exe "src\main.zig" `
        -target x86_64-windows-gnu `
        -O ReleaseFast `
        -femit-bin="$bin" `
        -lkernel32 -luser32 -lgdi32 -lole32 -lws2_32 -lshell32 -ladvapi32
    if ($LASTEXITCODE -ne 0) { throw "zig build-exe failed: $LASTEXITCODE" }

    $size = (Get-Item $bin).Length
    Write-Host "OK: $bin ($size bytes)"
} finally {
    Pop-Location
}
