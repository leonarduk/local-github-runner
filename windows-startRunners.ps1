<#
.SYNOPSIS
    Brings up every pool listed in windows-pools.conf. No arguments: "all of
    them" is defined by that file, same as startRunners.sh's Linux side.
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$conf = Join-Path $here 'windows-pools.conf'

if (-not (Test-Path $conf)) {
    throw "no windows-pools.conf -- cp windows-pools.conf.example windows-pools.conf and edit it"
}

Get-Content $conf | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $parts = $line -split '\s+'
    $name, $repo, $count = $parts[0], $parts[1], $(if ($parts.Count -ge 3) { [int]$parts[2] } else { 2 })
    Write-Host "== $name ($repo, x$count) =="
    & (Join-Path $here 'windows-pools.ps1') up $name $repo $count
}

Write-Host ''
& (Join-Path $here 'windows-pools.ps1') list
