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

if (-not (Test-Path $poolDir)) {
    Write-Host "Stop-RunnerPool: no pool directory for '$Name' -- nothing to stop"
    return
}

Get-ChildItem $poolDir -Directory -Filter 'slot-*' | ForEach-Object {
    $slot = $_.FullName
    $pidFile = Join-Path $slot '.pid'
    $stopFile = Join-Path $slot '.stop'

    New-Item -ItemType File -Force -Path $stopFile | Out-Null

    if (-not (Test-Path $pidFile)) {
        Write-Host "Stop-RunnerPool: $($_.Name) has no .pid file, nothing to signal"
        return
    }
    $procId = Get-Content $pidFile
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Host "Stop-RunnerPool: $($_.Name) pid $procId is not running"
        Remove-Item -Force $pidFile
        return
    }

    Write-Host "Stop-RunnerPool: signalled $($_.Name) (pid $procId), waiting up to ${TimeoutSeconds}s"
    $waited = 0
    while ((Get-Process -Id $procId -ErrorAction SilentlyContinue) -and $waited -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 2
        $waited += 2
    }

    if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
        if ($Force) {
            Write-Host "Stop-RunnerPool: $($_.Name) still running after ${TimeoutSeconds}s, forcing (-Force) -- any in-progress job is cut off"
            Stop-Process -Id $procId -Force
        } else {
            Write-Host "Stop-RunnerPool: $($_.Name) still running after ${TimeoutSeconds}s (likely mid-job) -- pass -Force to kill it, or wait longer"
            return
        }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $pidFile
}
