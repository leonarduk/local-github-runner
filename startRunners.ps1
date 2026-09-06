<#
.SYNOPSIS
    Brings up both fleets this host might be running -- the Linux Docker
    pools (pools.conf) and the native Windows pools (windows-pools.conf) --
    from one command. Only useful on a Windows host serving both; a
    Linux/macOS host has no Windows fleet to combine with, so it should just
    use startRunners.sh directly.

.NOTES
    This does not replace startRunners.sh or windows-startRunners.ps1 -- it
    wraps them, unchanged, so each remains the canonical single-fleet entry
    point (and the one CI or a bash-only host would actually use). Skips a
    fleet cleanly if that fleet's conf file does not exist yet, rather than
    failing the whole run for a host that only serves one of the two.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Bash {
    # Mirrors the README's own gotcha: on Windows, bare `bash` can silently
    # resolve to WSL's launcher in system32 rather than Git Bash, and gh
    # installed via winget is invisible from inside WSL. Prefer Git Bash's
    # well-known path; fall back to whatever's on PATH only if it doesn't
    # look like the WSL shim.
    $gitBash = 'C:\Program Files\Git\bin\bash.exe'
    if (Test-Path $gitBash) { return $gitBash }

    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch '\\(System32|WindowsApps)\\') { return $cmd.Source }
    return $null
}

$ranAny = $false

$linuxConf = Join-Path $here 'pools.conf'
if (Test-Path $linuxConf) {
    $ranAny = $true
    Write-Host '== Linux (Docker) pools =='
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $bash = Find-Bash
        if (-not $bash) {
            Write-Warning "pools.conf exists but no usable bash was found (Git Bash expected at 'C:\Program Files\Git\bin\bash.exe') -- skipping the Linux fleet. See README.md, 'Host prerequisites'."
        } else {
            & $bash './startRunners.sh'
        }
    } else {
        & bash './startRunners.sh'
    }
    Write-Host ''
} else {
    Write-Host '== Linux (Docker) pools == no pools.conf, skipping'
}

$windowsConf = Join-Path $here 'windows-pools.conf'
if (Test-Path $windowsConf) {
    $ranAny = $true
    Write-Host '== Windows (native) pools =='
    & (Join-Path $here 'windows-startRunners.ps1')
} else {
    Write-Host '== Windows (native) pools == no windows-pools.conf, skipping'
}

if (-not $ranAny) {
    throw "neither pools.conf nor windows-pools.conf exists -- see README.md and windows/README.md 'Quick start' to create one or both."
}
