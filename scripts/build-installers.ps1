<#
  Build Inno Setup installers for SecondDisplay Assembly and HolyC hosts.

  Outputs:
    releases\SecondDisplay-Asm-Setup-<ver>*.exe
    releases\SecondDisplay-HolyC-Setup-<ver>*.exe

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\build-installers.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build-installers.ps1 -Version 1.0.0
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$Target = '',
    [string]$Iscc = '',
    [switch]$SkipHostBuild
)

$ErrorActionPreference = 'Stop'

function Resolve-Tool([string]$explicit, [string[]]$candidates) {
    if ($explicit -and (Test-Path $explicit)) { return $explicit }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$releases = Join-Path $root 'releases'
New-Item -ItemType Directory -Force -Path $releases | Out-Null

Write-Host "=== SecondDisplay Installers Build (Version $Version) ===" -ForegroundColor Cyan

# ---------------------------------------------------------------- 1) Resolve Tools & Prerequisites
if (-not $Iscc) {
    $Iscc = Resolve-Tool '' @(
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        'C:\Users\admin\AppData\Local\Programs\Inno Setup 6\ISCC.exe'
    )
}
if (-not $Iscc) { throw "Inno Setup compiler (ISCC.exe) not found." }
Write-Host "ISCC: $Iscc" -ForegroundColor Gray

# Client APK
$apk = Join-Path $root 'android\SecondDisplay\app\build\outputs\apk\debug\app-debug.apk'
if (-not (Test-Path $apk)) {
    $altApk = Join-Path $root 'releases\android\app-debug.apk'
    if (Test-Path $altApk) { $apk = $altApk }
    else {
        $altApk2 = Join-Path $root 'build\staging\android\app-debug.apk'
        if (Test-Path $altApk2) { $apk = $altApk2 }
    }
}
if (-not (Test-Path $apk)) { throw "Android client APK not found: $apk" }
Write-Host "APK:  $apk ($( [math]::Round((Get-Item $apk).Length / 1MB, 2) ) MB)" -ForegroundColor Gray

# Platform-tools
$ptDir = Join-Path $root 'android\platform-tools'
if (-not (Test-Path (Join-Path $ptDir 'adb.exe'))) {
    $altPt = Join-Path $root 'build\staging\platform-tools'
    if (Test-Path (Join-Path $altPt 'adb.exe')) { $ptDir = $altPt }
}
foreach ($f in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
    if (-not (Test-Path (Join-Path $ptDir $f))) { throw "Missing platform-tools file: $f in $ptDir" }
}
Write-Host "Platform-tools: $ptDir" -ForegroundColor Gray

# Setup script helper
$setupPs1 = Join-Path $root 'installer\seconddisplay-setup.ps1'
if (-not (Test-Path $setupPs1)) { throw "Setup helper not found: $setupPs1" }

# ---------------------------------------------------------------- 2) Ensure Host Binaries
$asmExe = Join-Path $root 'build\host-asm\SecondDisplay.Host.Asm.exe'
if ((-not (Test-Path $asmExe)) -and (-not $SkipHostBuild)) {
    Write-Host "Building Assembly Host..." -ForegroundColor Yellow
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'host-asm\build.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Assembly host build failed ($LASTEXITCODE)" }
}

$holycExe = Join-Path $root 'build\host-holyc\SecondDisplay.Host.HolyC.exe'
if ((-not (Test-Path $holycExe)) -and (-not $SkipHostBuild)) {
    Write-Host "Building HolyC Host..." -ForegroundColor Yellow
    & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'host-holyc\build.ps1')
    if ($LASTEXITCODE -ne 0) { throw "HolyC host build failed ($LASTEXITCODE)" }
}

$csharpDir = Join-Path $root 'build\host-csharp'
$csharpProj = Join-Path $root 'host-c#\SecondDisplay.Host\SecondDisplay.Host.csproj'
if ((-not (Test-Path (Join-Path $csharpDir 'SecondDisplay.Host.exe'))) -and (-not $SkipHostBuild)) {
    Write-Host "Publishing C# Host (dotnet publish self-contained)..." -ForegroundColor Yellow
    & dotnet publish $csharpProj -c Release -r win-x64 --self-contained true -o $csharpDir
    if ($LASTEXITCODE -ne 0) { throw "C# host publish failed ($LASTEXITCODE)" }
}

$rustExe = Join-Path $root 'host-rs\target\release\seconddisplay-host.exe'
if ((-not (Test-Path $rustExe)) -and (-not $SkipHostBuild)) {
    Write-Host "Building Rust Host..." -ForegroundColor Yellow
    & cargo build --release --manifest-path (Join-Path $root 'host-rs\Cargo.toml')
    if ($LASTEXITCODE -ne 0) { throw "Rust host build failed ($LASTEXITCODE)" }
    $manifestXml = Join-Path $root 'host-c#\SecondDisplay.Host\app.manifest'
    $mt = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\mt.exe'
    if (Test-Path $mt) {
        & $mt -manifest $manifestXml "-outputresource:${rustExe};#1"
    }
}

# ---------------------------------------------------------------- 3) Stage and Compile Hosts
$allTargets = @(
    @{
        Name = 'HolyC'
        Short = 'HolyC'
        Iss = (Join-Path $root 'installer\SecondDisplay-HolyC.iss')
        HostSource = $holycExe
        IsDirectory = $false
        HostName = 'SecondDisplay.Host.HolyC.exe'
        StagingDir = (Join-Path $root 'build\staging-holyc')
    },
    @{
        Name = 'Assembly'
        Short = 'Asm'
        Iss = (Join-Path $root 'installer\SecondDisplay-Asm.iss')
        HostSource = $asmExe
        IsDirectory = $false
        HostName = 'SecondDisplay.Host.Asm.exe'
        StagingDir = (Join-Path $root 'build\staging-asm')
    },
    @{
        Name = 'C#'
        Short = 'CSharp'
        Iss = (Join-Path $root 'installer\SecondDisplay-CSharp.iss')
        HostSource = $csharpDir
        IsDirectory = $true
        HostName = 'SecondDisplay.Host.exe'
        StagingDir = (Join-Path $root 'build\staging-csharp')
    },
    @{
        Name = 'Rust'
        Short = 'Rust'
        Iss = (Join-Path $root 'installer\SecondDisplay-Rust.iss')
        HostSource = $rustExe
        IsDirectory = $false
        HostName = 'SecondDisplay.Host.Rust.exe'
        StagingDir = (Join-Path $root 'build\staging-rust')
    }
)

$targets = if ($Target) {
    $allTargets | Where-Object { $_.Short -ieq $Target -or $_.Name -ieq $Target }
} else {
    $allTargets
}

if (-not $targets -or $targets.Count -eq 0) {
    throw "No matching targets found for '$Target'. Valid options: Asm, HolyC, CSharp, Rust"
}

$produced = @()

foreach ($t in $targets) {
    Write-Host "`nStaging files for $($t.Name) Host..." -ForegroundColor Cyan
    $staging = $t.StagingDir
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    $hostDir = Join-Path $staging 'host'
    $stagingPt = Join-Path $staging 'platform-tools'
    $stagingAndroid = Join-Path $staging 'android'
    New-Item -ItemType Directory -Force -Path $hostDir, $stagingPt, $stagingAndroid | Out-Null

    if ($t.IsDirectory) {
        Copy-Item (Join-Path $t.HostSource '*') $hostDir -Recurse -Force
    } else {
        Copy-Item $t.HostSource (Join-Path $hostDir $t.HostName) -Force
        Copy-Item $t.HostSource (Join-Path $hostDir 'SecondDisplay.Host.exe') -Force
    }

    # Copy platform tools
    foreach ($f in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
        Copy-Item (Join-Path $ptDir $f) (Join-Path $stagingPt $f) -Force
    }

    # Copy client APK
    Copy-Item $apk (Join-Path $stagingAndroid 'app-debug.apk') -Force

    # Copy setup helper script
    Copy-Item $setupPs1 (Join-Path $staging 'seconddisplay-setup.ps1') -Force

    Write-Host "Compiling unified multilingual installer for $($t.Name)..." -ForegroundColor Cyan
    $isccArgs = @(
        "/DMyAppVersion=$Version",
        "/DSourceDir=$staging",
        $t.Iss
    )

    & $Iscc @isccArgs
    if ($LASTEXITCODE -ne 0) { throw "ISCC compilation failed for $($t.Name) (exit code: $LASTEXITCODE)" }

    $outBase = "SecondDisplay-$($t.Short)-Setup-$Version.exe"
    $expectedPath = Join-Path $releases $outBase
    if (-not (Test-Path $expectedPath)) { throw "Expected installer not found: $expectedPath" }

    $fi = Get-Item $expectedPath
    $mb = [math]::Round($fi.Length / 1MB, 2)
    $produced += [PSCustomObject]@{
        Installer = $outBase
        Path = $expectedPath
        Target = $t.Name
        Lang = 'Multilingual (RU/EN)'
        SizeBytes = $fi.Length
        SizeMB = $mb
        ValidSize = ($fi.Length -gt 5MB)
    }
}

Write-Host "`n=== Build Completed Successfully ===" -ForegroundColor Green
$produced | Format-Table -AutoSize Installer, Target, Lang, SizeMB, ValidSize

# Check that all files exceed 5 MB threshold
$failed = $produced | Where-Object { -not $_.ValidSize }
if ($failed.Count -gt 0) {
    throw "One or more installers failed size validation (> 5 MB): $($failed.Installer -join ', ')"
}

return $produced
