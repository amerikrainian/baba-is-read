# Build the distributable mod zip: the game-folder layout the mod lives in (Data\Lua\baba_access.lua,
# Data\Lua\baba_access\** with babaaccess.dll and prism.dll under bin\), freshly compiled, as
# releases\BabaAccess-v<version>.zip. The zip root IS the game folder, so the installer (and a manual
# user) extracts it straight into the game dir. The version is the mod's own
# (lua\baba_access\version.lua), which is also the release tag.
#
# Not shipped: the dev server's scratch (lua\baba_access\cmd\, gitignored) and anything else not
# checked in.
#
# Adapted from the Non-Visual Calculus installer by Rashad Naqeeb (MIT),
# https://github.com/rashadnaqeeb/NonVisualCalculus

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$versionFile = Join-Path $scriptDir "lua\baba_access\version.lua"
$releaseDir = Join-Path $scriptDir "releases"
$stageDir = Join-Path $scriptDir "obj\release-stage"

$versionText = Get-Content -LiteralPath $versionFile -Raw
if ($versionText -notmatch 'return\s+"(\d+\.\d+\.\d+)"') {
    throw "Could not read a three-part version from $versionFile"
}
$version = $Matches[1]

$luaDir = Join-Path $scriptDir "lua"
$bootstrap = Join-Path $luaDir "baba_access.lua"
$modSrcDir = Join-Path $luaDir "baba_access"
$bridgeDll = Join-Path $scriptDir "build\babaaccess.dll"
$prismDll = Join-Path $scriptDir "third_party\prism\prism.dll"
$zipPath = Join-Path $releaseDir "BabaAccess-v$version.zip"

# Directories under lua\baba_access\ that are never part of a release.
$excludedDirs = @("cmd")

if (-not (Test-Path $prismDll)) {
    throw "Required file not found: $prismDll"
}

Push-Location $scriptDir
try {
    # A fresh bridge, so a stale DLL in build\ never ships.
    if (Test-Path $bridgeDll) {
        Remove-Item -LiteralPath $bridgeDll -Force
    }
    & (Join-Path $scriptDir "build.ps1") -NoDeploy
    if (-not (Test-Path $bridgeDll)) {
        throw "Release build output not found: $bridgeDll"
    }

    if (Test-Path $stageDir) {
        Remove-Item -LiteralPath $stageDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force $stageDir | Out-Null
    New-Item -ItemType Directory -Force $releaseDir | Out-Null

    # The same layout build.ps1 deploys: the bootstrap in Data\Lua, the modules under baba_access\.
    $stageLuaDir = Join-Path $stageDir "Data\Lua"
    $stageModDir = Join-Path $stageLuaDir "baba_access"
    $stageBinDir = Join-Path $stageModDir "bin"
    New-Item -ItemType Directory -Force $stageBinDir | Out-Null
    Copy-Item -LiteralPath $bootstrap -Destination $stageLuaDir

    $modFiles = Get-ChildItem $modSrcDir -Recurse -File | Where-Object {
        $rel = $_.FullName.Substring($modSrcDir.Length + 1)
        $top = $rel.Split([IO.Path]::DirectorySeparatorChar)[0]
        $excludedDirs -notcontains $top
    }
    foreach ($file in $modFiles) {
        $rel = $file.FullName.Substring($modSrcDir.Length + 1)
        $dest = Join-Path $stageModDir $rel
        New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $dest
    }

    Copy-Item -LiteralPath $bridgeDll -Destination $stageBinDir
    Copy-Item -LiteralPath $prismDll -Destination $stageBinDir

    foreach ($required in @("Data\Lua\baba_access.lua", "Data\Lua\baba_access\main.lua",
            "Data\Lua\baba_access\bin\babaaccess.dll", "Data\Lua\baba_access\bin\prism.dll")) {
        if (-not (Test-Path (Join-Path $stageDir $required))) {
            throw "The staged release lacks $required"
        }
    }

    if (Test-Path $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath -Force

    Remove-Item -LiteralPath $stageDir -Recurse -Force

    Write-Host "Release zip: $zipPath"
}
finally {
    Pop-Location
}
