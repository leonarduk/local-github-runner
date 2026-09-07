<#
.SYNOPSIS
    Pre-populates a persistent RUNNER_TOOL_CACHE with a Python install so
    actions/setup-python finds it already there and skips its own
    download-and-install step.

.NOTES
    Why this exists: actions/setup-python, when the tool cache doesn't
    already have a matching version, downloads a python-versions release
    zip and runs its bundled setup.ps1, which tries to remove old registry
    uninstall entries under HKLM and then run the official python.org
    installer exe. Both steps assume an elevated/admin process. Our runner
    processes run as the logged-in user (see runner-loop.ps1's header), so
    that install fails every time on a cache miss.

    The fix is to make sure it's never a cache miss: install once here,
    per-user (InstallAllUsers=0, so no admin rights needed) into a
    persistent toolcache directory that lives outside any runner slot's
    ephemeral _work, and lay it out the way actions/toolkit expects --
    <cache>\Python\<version>\<arch>\ plus a sibling <arch>.complete marker
    file. Start-RunnerPool.ps1 points RUNNER_TOOL_CACHE at that directory.

    actions/setup-python resolves a version spec like "3.11" against the
    tool cache using a semver range match, not an exact string match, so
    caching the single patch version below satisfies any workflow asking
    for "3.11" or "3.11.x" -- it does not need to be the newest 3.11.z.

    Checksum came from downloading the installer once and hashing it
    ourselves (python.org's release page only publishes MD5s); same
    "refuse to install what we can't verify" spirit as Install-Runner.ps1.
#>
[CmdletBinding()]
param(
    [string]$ToolCacheDir,
    [string]$Version = '3.11.9',
    [ValidateSet('x64', 'x86')] [string]$Arch = 'x64',
    [string]$Sha256 = '5EE42C4EEE1E6B4464BB23722F90B45303F79442DF63083F05322F1785F5FDDE',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot   # repo root, since this file lives in windows\
if (-not $ToolCacheDir) { $ToolCacheDir = Join-Path $root 'windows\toolcache' }

$versionDir  = Join-Path $ToolCacheDir "Python\$Version\$Arch"
$markerFile  = Join-Path $ToolCacheDir "Python\$Version\$Arch.complete"

if ((Test-Path $markerFile) -and -not $Force) {
    Write-Host "Install-PythonToolCache: $Version ($Arch) already cached at $versionDir, skipping (-Force to reinstall)"
    return
}

if (Test-Path $versionDir) { Remove-Item -Recurse -Force $versionDir }
Remove-Item -Force -ErrorAction SilentlyContinue $markerFile
New-Item -ItemType Directory -Force -Path $versionDir | Out-Null

$installerArch = if ($Arch -eq 'x64') { 'amd64' } else { '' }
$asset = "python-$Version-$installerArch.exe"
$url   = "https://www.python.org/ftp/python/$Version/$asset"
$installerPath = Join-Path $env:TEMP $asset

Write-Host "Install-PythonToolCache: downloading $url"
Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing

$actual = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
if ($actual.ToUpperInvariant() -ne $Sha256.ToUpperInvariant()) {
    Remove-Item $installerPath -Force
    throw "Install-PythonToolCache: SHA256 mismatch for $asset -- expected $Sha256, got $actual. Refusing to install a Python build that does not match its published digest."
}

Write-Host "Install-PythonToolCache: checksum OK, installing per-user into $versionDir"
# InstallAllUsers=0 and a custom TargetDir keep this off HKLM and Program
# Files entirely, so it needs no admin rights -- the whole point, since
# that's what the automatic setup-python path can't do from this runner.
$proc = Start-Process -FilePath $installerPath -ArgumentList @(
    '/quiet',
    'InstallAllUsers=0',
    'PrependPath=0',
    'Include_launcher=0',
    'Include_test=0',
    "TargetDir=$versionDir"
) -Wait -PassThru
Remove-Item $installerPath -Force

if ($proc.ExitCode -ne 0) {
    throw "Install-PythonToolCache: python installer exited with code $($proc.ExitCode)"
}
if (-not (Test-Path (Join-Path $versionDir 'python.exe'))) {
    throw "Install-PythonToolCache: install reported success but $versionDir\python.exe is missing"
}

New-Item -ItemType File -Force -Path $markerFile | Out-Null
Write-Host "Install-PythonToolCache: done (Python $Version $Arch -> $versionDir)"
