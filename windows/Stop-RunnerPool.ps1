<#
.SYNOPSIS
    Windows equivalent of `pools.sh down`: stop every slot in a pool,
    deregistering cleanly where possible.

.EXAMPLE
    .\windows\Stop-RunnerPool.ps1 -Name jobtrack
    .\windows\Stop-RunnerPool.ps1 -Name jobtrack -Force -TimeoutSeconds 30
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Name,
    # Without -Force, a slot mid-job is left to finish its current job and
    # deregister itself normally -- same spirit as compose's stop_grace_period,
    # just with no fixed grace period because there is no container to reap.
    [switch]$Force,
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$poolDir = Join-Path $root "windows\runners\$Name"

. (Join-Path $PSScriptRoot 'PoolSlot.ps1')

if (-not (Test-Path $poolDir)) {
    Write-Host "Stop-RunnerPool: no pool directory for '$Name' -- nothing to stop"
    return
}

Get-ChildItem $poolDir -Directory -Filter 'slot-*' | ForEach-Object {
    [void](Stop-Slot -SlotDir $_.FullName -SlotLabel $_.Name -Force:$Force -TimeoutSeconds $TimeoutSeconds)
}
