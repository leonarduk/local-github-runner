<#
.SYNOPSIS
    Tears down every pool listed in windows-pools.conf. Each slot deregisters
    itself on the way out where possible -- see windows/README.md, "Teardown".
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$conf = Join-Path $here 'windows-pools.conf'

if (-not (Test-Path $conf)) {
    throw "no windows-pools.conf -- cp windows-pools.conf.example windows-pools.conf and edit it"
}

Get-Content $conf | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $name = ($line -split '\s+')[0]
    Write-Host "== $name =="
    if ($Force) {
        & (Join-Path $here 'windows\Stop-RunnerPool.ps1') -Name $name -Force
    } else {
        & (Join-Path $here 'windows\Stop-RunnerPool.ps1') -Name $name
    }
}
