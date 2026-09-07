<#
.SYNOPSIS
    Pre-populates the persistent RUNNER_TOOL_CACHE (see Install-PythonToolCache.ps1
    for why) with a Node.js install, so actions/setup-node finds it already
    there instead of trying to fetch and unpack one itself.

.NOTES
    Node's Windows distribution is a plain zip (no installer exe, no
    registry writes), so there's no elevation problem here the way there is
    for Python -- this script exists mainly so jobtrack and issue-worm-pro's
    Windows pools have Node ready too, on the same "never let it be a cache
    miss" principle, rather than because a job has actually failed on this
    yet.

    Checksums come from Node's own published SHASUMS256.txt for the release
    (unlike python.org, which only publishes MD5s) -- same "refuse to
    install what we can't verify" spirit as Install-Runner.ps1.
#>
[CmdletBinding()]
param(
    [string]$ToolCacheDir,
    [Parameter(Mandatory)] [string]$Version,
    [ValidateSet('x64', 'x86')] [string]$Arch = 'x64',
    [Parameter(Mandatory)] [string]$Sha256,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot   # repo root, since this file lives in windows\
if (-not $ToolCacheDir) { $ToolCacheDir = Join-Path $root 'windows\toolcache' }

$versionDir = Join-Path $ToolCacheDir "node\$Version\$Arch"
$markerFile = Join-Path $ToolCacheDir "node\$Version\$Arch.complete"

if ((Test-Path $markerFile) -and -not $Force) {
    Write-Host "Install-NodeToolCache: $Version ($Arch) already cached at $versionDir, skipping (-Force to reinstall)"
    return
}

if (Test-Path $versionDir) { Remove-Item -Recurse -Force $versionDir }
Remove-Item -Force -ErrorAction SilentlyContinue $markerFile
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $versionDir) | Out-Null

$asset = "node-$Version-win-$Arch.zip"
$url   = "https://nodejs.org/dist/$Version/$asset"
$zipPath = Join-Path $env:TEMP $asset

Write-Host "Install-NodeToolCache: downloading $url"
Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

$actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
if ($actual.ToUpperInvariant() -ne $Sha256.ToUpperInvariant()) {
    Remove-Item $zipPath -Force
    throw "Install-NodeToolCache: SHA256 mismatch for $asset -- expected $Sha256, got $actual. Refusing to unpack a Node build that does not match its published digest."
}

Write-Host "Install-NodeToolCache: checksum OK, unpacking into $versionDir"
$extractDir = Join-Path $env:TEMP "node-extract-$([guid]::NewGuid())"
Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
Remove-Item $zipPath -Force

# The zip's own top-level folder is "node-<version>-win-<arch>\" -- move its
# contents up a level so node.exe lands directly in $versionDir, matching
# the layout actions/toolkit's tool-cache expects (<cache>\node\<version>\<arch>\node.exe).
$innerDir = Join-Path $extractDir "node-$Version-win-$Arch"
Move-Item -Path $innerDir -Destination $versionDir
Remove-Item -Recurse -Force $extractDir

if (-not (Test-Path (Join-Path $versionDir 'node.exe'))) {
    throw "Install-NodeToolCache: extraction reported success but $versionDir\node.exe is missing"
}

New-Item -ItemType File -Force -Path $markerFile | Out-Null
Write-Host "Install-NodeToolCache: done (Node $Version $Arch -> $versionDir)"
