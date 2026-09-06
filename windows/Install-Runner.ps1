<#
.SYNOPSIS
    Downloads, checksum-verifies, and unpacks the GitHub Actions runner for
    Windows into a slot directory. One slot = one runner identity, the same
    way one container is one runner in the Linux/Docker half of this repo.

.NOTES
    Pinned and checksummed for the same reason as the Linux tarball in the
    Dockerfile: a corrupted or substituted zip should fail loudly, not get
    unpacked and run. Bump -Version and the matching -Sha256Win64/-Sha256WinArm64
    default together; the digests come from the release's own asset list --
        gh api repos/actions/runner/releases/tags/vX.Y.Z --jq '.assets[] | {name,digest}'
    -- not from the release notes body, which does not carry checksums for
    any platform.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Path,
    [string]$Version = '2.337.0',
    [ValidateSet('x64', 'arm64')] [string]$Arch = 'x64',
    [string]$Sha256Win64   = '1150692afa94e71f872017e254ea55b6eece1eece3fe7e3a6d4c93d0a1b85cfc',
    [string]$Sha256WinArm64 = '7ee1a72a0e0ad384ac7871ffc2356063a116e20d1db3ea41000eb49272cf0030',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if ((Test-Path (Join-Path $Path 'config.cmd')) -and -not $Force) {
    Write-Host "Install-Runner: $Path already has a runner installed, skipping (-Force to reinstall)"
    return
}

$sha256 = if ($Arch -eq 'x64') { $Sha256Win64 } else { $Sha256WinArm64 }
$asset  = "actions-runner-win-$Arch-$Version.zip"
$url    = "https://github.com/actions/runner/releases/download/v$Version/$asset"

New-Item -ItemType Directory -Force -Path $Path | Out-Null
$zipPath = Join-Path $Path $asset

Write-Host "Install-Runner: downloading $url"
Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing

$actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
if ($actual.ToLowerInvariant() -ne $sha256.ToLowerInvariant()) {
    Remove-Item $zipPath -Force
    throw "Install-Runner: SHA256 mismatch for $asset -- expected $sha256, got $actual. Refusing to unpack a runner that does not match its published digest."
}

Write-Host "Install-Runner: checksum OK, unpacking into $Path"
Expand-Archive -Path $zipPath -DestinationPath $Path -Force
Remove-Item $zipPath -Force

Write-Host "Install-Runner: done ($asset -> $Path)"
