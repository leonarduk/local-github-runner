<#
.SYNOPSIS
    Tears down both fleets this host might be running -- the Linux Docker
    pools (pools.conf) and the native Windows pools (windows-pools.conf) --
    from one command. Counterpart to startRunners.ps1; same rationale for
    wrapping rather than replacing the single-fleet scripts.

.EXAMPLE
    .\stopRunners.ps1          # Windows slots wait for an in-progress job to finish
    .\stopRunners.ps1 -Force   # Windows slots are killed outright instead
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Find-Bash {
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
            & $bash './stopRunners.sh'
        }
    } else {
        & bash './stopRunners.sh'
    }
    Write-Host ''
} else {
    Write-Host '== Linux (Docker) pools == no pools.conf, skipping'
}

$windowsConf = Join-Path $here 'windows-pools.conf'
if (Test-Path $windowsConf) {
    $ranAny = $true
    Write-Host '== Windows (native) pools =='
    if ($Force) {
        & (Join-Path $here 'windows-stopRunners.ps1') -Force
    } else {
        & (Join-Path $here 'windows-stopRunners.ps1')
    }
} else {
    Write-Host '== Windows (native) pools == no windows-pools.conf, skipping'
}

if (-not $ranAny) {
    throw "neither pools.conf nor windows-pools.conf exists -- nothing to stop."
}
