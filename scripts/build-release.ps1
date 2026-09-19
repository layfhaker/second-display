<#
  Build a release installer for SecondDisplay.

  Steps:
    1. cargo build --release the Rust host            -> build\staging\host\SecondDisplay.Host.exe
    2. build the Android client APK (gradle)          -> build\staging\android
    3. copy platform-tools (adb + 2 dll)              -> build\staging\platform-tools
    4. compile the Inno Setup installers (all/ru/en)  -> releases\SecondDisplay-Setup-<ver>*.exe

  Requires: Rust toolchain, JDK 17 + Android SDK + Gradle, and Inno Setup 6.

  Usage:
    powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1
    powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1 -Version 1.2.0
#>
[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Configuration = 'Release',
    [string]$SdkDir = '',
    [string]$GradleExe = '',
    [string]$JavaHome = '',
    [string]$Iscc = ''
)

$ErrorActionPreference = 'Stop'

function Resolve-Tool([string]$explicit, [string[]]$candidates) {
    if ($explicit -and (Test-Path $explicit)) { return $explicit }
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$androidProj = Join-Path $root 'android\SecondDisplay'
$staging = Join-Path $root 'build\staging'
$releases = Join-Path $root 'releases'

if (-not $Version) { $Version = Get-Date -Format 'yyyy.MM.dd' }

Write-Host "=== SecondDisplay release build (version $Version) ===" -ForegroundColor Cyan

# ---------------------------------------------------------------- staging
if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path `
    (Join-Path $staging 'host'), (Join-Path $staging 'android'), (Join-Path $staging 'platform-tools'), $releases | Out-Null

# ---------------------------------------------------------------- 1) host (Rust)
Write-Host "[1/4] building Rust host (cargo build --release)..." -ForegroundColor Cyan
& cargo build --release --manifest-path (Join-Path $root 'host-rs\Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }
Copy-Item (Join-Path $root 'host-rs\target\release\seconddisplay-host.exe') (Join-Path $staging 'host\SecondDisplay.Host.exe') -Force

# ---------------------------------------------------------------- 2) android apk
Write-Host "[2/4] building android client APK..." -ForegroundColor Cyan

# Android SDK: -SdkDir > ANDROID_HOME > local.properties sdk.dir
if (-not $SdkDir) { $SdkDir = $env:ANDROID_HOME }
if (-not $SdkDir -and -not $env:ANDROID_SDK_ROOT) { $SdkDir = '' } else { if (-not $SdkDir) { $SdkDir = $env:ANDROID_SDK_ROOT } }
if (-not $SdkDir) {
    $lp = Join-Path $androidProj 'local.properties'
    if (Test-Path $lp) {
        $line = Select-String -Path $lp -Pattern '^\s*sdk\.dir\s*=\s*(.+)$' | Select-Object -First 1
        if ($line) { $SdkDir = ($line.Matches[0].Groups[1].Value.Trim() -replace '\\\\', '\' -replace '\\:', ':') }
    }
}
if (-not $SdkDir) { throw "Android SDK not found. Pass -SdkDir or set ANDROID_HOME." }
$env:ANDROID_HOME = $SdkDir
$env:ANDROID_SDK_ROOT = $SdkDir

# Java: -JavaHome > JAVA_HOME > Android Studio JBR
if (-not $JavaHome) { $JavaHome = $env:JAVA_HOME }
if (-not $JavaHome) {
    $jbr = Resolve-Tool '' @(
        "$env:ProgramFiles\Android\Android Studio\jbr",
        "$env:LOCALAPPDATA\Programs\Android Studio\jbr")
    if ($jbr) { $JavaHome = $jbr }
}
if ($JavaHome) { $env:JAVA_HOME = $JavaHome; Write-Host "  JAVA_HOME=$JavaHome" }

# Gradle: -GradleExe > GRADLE_HOME > PATH > Android Studio bundled > wrapper dists / common dirs
if (-not $GradleExe -and $env:GRADLE_HOME) {
    $g = Join-Path $env:GRADLE_HOME 'bin\gradle.bat'
    if (Test-Path $g) { $GradleExe = $g }
}
if (-not $GradleExe) { $GradleExe = (Get-Command gradle -ErrorAction SilentlyContinue).Source }
if (-not $GradleExe) {
    $patterns = @(
        "$env:ProgramFiles\Android\Android Studio\gradle\gradle-*\bin\gradle.bat",
        "$env:LOCALAPPDATA\Programs\Android Studio\gradle\gradle-*\bin\gradle.bat",
        "C:\Users\*\android-build\gradle\gradle-*\bin\gradle.bat",
        "C:\Users\*\*\android-build\gradle\gradle-*\bin\gradle.bat",
        "C:\Users\*\*\gradle\wrapper\dists\gradle-*\*\gradle-*\bin\gradle.bat",
        "$env:USERPROFILE\.gradle\wrapper\dists\gradle-*\*\gradle-*\bin\gradle.bat"
    )
    $cand = @()
    foreach ($p in $patterns) {
        $cand += @(Get-ChildItem $p -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }
    $GradleExe = $cand | Sort-Object -Descending | Select-Object -First 1
}
if (-not $GradleExe) { throw "Gradle not found. Pass -GradleExe or put gradle on PATH." }
Write-Host "  gradle=$GradleExe"

& $GradleExe -p $androidProj :app:assembleDebug --console=plain
if ($LASTEXITCODE -ne 0) { throw "gradle assembleDebug failed ($LASTEXITCODE)" }
Copy-Item (Join-Path $androidProj 'app\build\outputs\apk\debug\app-debug.apk') (Join-Path $staging 'android\app-debug.apk') -Force

# ---------------------------------------------------------------- 3) platform-tools
Write-Host "[3/4] staging platform-tools..." -ForegroundColor Cyan
$pt = Join-Path $SdkDir 'platform-tools'
foreach ($f in @('adb.exe', 'AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
    $src = Join-Path $pt $f
    if (-not (Test-Path $src)) { throw "Missing $f in $pt" }
    Copy-Item $src (Join-Path $staging 'platform-tools') -Force
}
Copy-Item (Join-Path $root 'installer\seconddisplay-setup.ps1') (Join-Path $staging 'seconddisplay-setup.ps1') -Force

# ---------------------------------------------------------------- 4) installer (per language)
if (-not $Iscc) {
    $Iscc = Resolve-Tool '' @(
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")
}
if (-not $Iscc) { throw "Inno Setup (ISCC.exe) not found. Install it: winget install JRSoftware.InnoSetup" }

# no extra define = one multi-language installer; /DLangRu or /DLangEn = single-language installers.
$langs = @(
    @{ Id = 0; Name = '';   Define = '' },
    @{ Id = 1; Name = 'ru'; Define = '/DLangRu' },
    @{ Id = 2; Name = 'en'; Define = '/DLangEn' }
)
$produced = @()
foreach ($lang in $langs) {
    $label = if ($lang.Name) { $lang.Name } else { 'all' }
    Write-Host "[4/4] compiling installer (lang=$label)..." -ForegroundColor Cyan
    $isccArgs = @("/DMyAppVersion=$Version", "/DSourceDir=$staging")
    if ($lang.Define) { $isccArgs += $lang.Define }
    $isccArgs += (Join-Path $root 'installer\SecondDisplay.iss')
    & $Iscc @isccArgs
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed for lang=$label ($LASTEXITCODE)" }
    $name = if ($lang.Name) { "SecondDisplay-Setup-$Version-$($lang.Name).exe" } else { "SecondDisplay-Setup-$Version.exe" }
    $setup = Join-Path $releases $name
    if (-not (Test-Path $setup)) { throw "Installer not produced: $setup" }
    $produced += $setup
}

Write-Host ""
Write-Host "DONE - installers in ${releases}:" -ForegroundColor Green
foreach ($p in $produced) {
    $leaf = Split-Path $p -Leaf
    $mb = [math]::Round((Get-Item $p).Length / 1MB, 1)
    Write-Host "  $leaf ($mb MB)"
}
