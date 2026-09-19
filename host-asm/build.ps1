<#
  Build the assembly host (MASM x64).

  Uses the Visual Studio Build Tools toolchain: vcvars64.bat -> ml64 -> link.
  Output: build\host-asm\SecondDisplay.Host.Asm.exe

  Usage:
    powershell -ExecutionPolicy Bypass -File host-asm\build.ps1
#>
param([string]$Configuration = 'Release')

$ErrorActionPreference = 'Stop'

$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$asmSrc = Join-Path $root 'host-asm\src\main.asm'
$outDir = Join-Path $root 'build\host-asm'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) { throw "vcvars64.bat not found: $vcvars" }

$obj = Join-Path $outDir 'main.obj'
$exe = Join-Path $outDir 'SecondDisplay.Host.Asm.exe'

& cmd /c "call `"$vcvars`" >nul && ml64 /nologo /c /Fo`"$obj`" `"$asmSrc`" && link /nologo /SUBSYSTEM:CONSOLE /ENTRY:mainCRTStartup /OUT:`"$exe`" `"$obj`" kernel32.lib ws2_32.lib ole32.lib dxgi.lib d3d11.lib"
if ($LASTEXITCODE -ne 0) { throw "assembly build failed ($LASTEXITCODE)" }

Write-Host "DONE: $exe" -ForegroundColor Green
