<#
.SYNOPSIS
Builds the native bridge and deploys the mod into the game.

.PARAMETER GameDir
The Baba Is You install directory. Defaults to $env:BABA_DIR, then the Steam default.

.PARAMETER NoDeploy
Compile only.

.PARAMETER NoBuild
Deploy only (Lua and prebuilt DLL).
#>
param(
    [string]$GameDir = "",
    [switch]$NoDeploy,
    [switch]$NoBuild
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

if ($GameDir -eq "") {
    if ($env:BABA_DIR) { $GameDir = $env:BABA_DIR }
    else { $GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Baba Is You" }
}

$buildDir = Join-Path $root "build"
$dll = Join-Path $buildDir "babaisread.dll"

if (-not $NoBuild) {
    New-Item -ItemType Directory -Force $buildDir | Out-Null
    $sources = Get-ChildItem (Join-Path $root "native") -Filter *.c | ForEach-Object { $_.FullName }
    Write-Host "Compiling $($sources.Count) sources -> $dll"
    & gcc -shared -O2 -Wall -Wextra -Wno-unused-parameter -static -o $dll @sources -lws2_32 -luser32 -lkernel32
    if ($LASTEXITCODE -ne 0) { throw "gcc failed with exit code $LASTEXITCODE" }
}

if (-not $NoDeploy) {
    if (-not (Test-Path (Join-Path $GameDir "Baba Is You.exe"))) { throw "Game not found at $GameDir" }
    $luaDir = Join-Path $GameDir "Data\Lua"
    $modDir = Join-Path $luaDir "baba_is_read"
    $binDir = Join-Path $modDir "bin"
    New-Item -ItemType Directory -Force $binDir | Out-Null

    # Lua: the bootstrap at the top level, the modules under baba_is_read\.
    Copy-Item (Join-Path $root "lua\baba_is_read.lua") $luaDir -Force
    $srcMod = Join-Path $root "lua\baba_is_read"
    Get-ChildItem $srcMod -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($srcMod.Length + 1)
        $dest = Join-Path $modDir $rel
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item $_.FullName $dest -Force
    }

    # Native: the bridge and Prism, side by side.
    if (Test-Path $dll) {
        try { Copy-Item $dll $binDir -Force -ErrorAction Stop }
        catch { Write-Warning "bridge DLL not updated (is the game running?): $($_.Exception.Message)" }
    }
    try { Copy-Item (Join-Path $root "third_party\prism\prism.dll") $binDir -Force -ErrorAction Stop }
    catch { Write-Warning "prism.dll not updated (is the game running?): $($_.Exception.Message)" }

    Write-Host "Deployed to $modDir"
}
