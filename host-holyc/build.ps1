<#
  Build the HolyC host for SecondDisplay (MSVC x64).

  Uses the HolyC preprocessor (tools/holyc.py) and MSVC toolchain (vcvars64.bat -> cl).
  Output: build\host-holyc\SecondDisplay.Host.HolyC.exe

  Usage:
    powershell -ExecutionPolicy Bypass -File host-holyc\build.ps1
#>
param(
    [string]$Configuration = 'Release',
    [switch]$VerboseOutput
)

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$srcHC = Join-Path $root 'host-holyc\src\host.HC'
$outDir = Join-Path $root 'build\host-holyc'
$exe = Join-Path $outDir 'SecondDisplay.Host.HolyC.exe'
$holycPy = Join-Path $root 'host-holyc\tools\holyc.py'

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) {
    throw "vcvars64.bat not found at: $vcvars"
}

Write-Host "=== Building SecondDisplay HolyC Host ===" -ForegroundColor Cyan
Write-Host "Source: $srcHC"
Write-Host "Target: $exe"

$vFlag = if ($VerboseOutput) { "-v" } else { "" }

python $holycPy $srcHC -o $exe --vcvars $vcvars $vFlag

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
    throw "HolyC build failed with exit code $LASTEXITCODE"
}

$fileInfo = Get-Item $exe
Write-Host ("SUCCESS: Built {0} ({1:N0} bytes)" -f $exe, $fileInfo.Length) -ForegroundColor Green
