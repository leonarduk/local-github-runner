<#
.SYNOPSIS
    Restart one runner slot, identified by the GitHub runner name it
    registers under (the "container" field windows-pools.ps1 list -Json
    reports for each member) -- the Windows analogue of pools.sh's
    restart-runner, for one slot instead of a whole pool.

.DESCRIPTION
    Refuses (exit 3) if GitHub says that slot's runner is busy, unless
    -Force. Searches every pool directory under windows\runners\ (not just
    ones windows-pools.conf declares) for a slot whose computed runner name
    matches -RunnerName, the same way pools.sh's restart-runner works on
    any docker container on the host, declared or not.

.EXAMPLE
    .\windows\Restart-RunnerSlot.ps1 -RunnerName HOST-HOST-jobtrack-slot1
    .\windows\Restart-RunnerSlot.ps1 -RunnerName HOST-HOST-jobtrack-slot1 -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RunnerName,
    [switch]$Force,
    [string]$RunnersRoot,
    [string]$HostLabel = $env:COMPUTERNAME,
    [string]$PatFile,
    [string]$RunnerVersion = '2.337.0',
    [ValidateSet('x64', 'arm64')] [string]$Arch = 'x64',
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $RunnersRoot) { $RunnersRoot = Join-Path $root 'windows\runners' }
if (-not $PatFile) { $PatFile = Join-Path $root 'pat.secret' }

. (Join-Path $PSScriptRoot 'PoolSlot.ps1')

if (-not (Test-Path $RunnersRoot)) {
    Invoke-PoolDie "no runner slot found for '$RunnerName' on this host -- $RunnersRoot doesn't exist"
}

# Find the pool/slot whose computed runner name matches. Not parsed back
# out of the name (HostLabel, COMPUTERNAME and Name can all contain
# dashes, which would make that ambiguous) -- searched for instead, the
# same way `docker inspect` looks a container up by name rather than
# pools.sh trying to parse one apart.
$foundPoolName = $null
$foundPoolDir = $null
$foundIndex = $null
foreach ($poolDir in (Get-ChildItem -Path $RunnersRoot -Directory -ErrorAction SilentlyContinue)) {
    foreach ($slotDir in (Get-PoolSlotDirs -PoolDir $poolDir.FullName)) {
        $idx = Get-SlotIndex -SlotName $slotDir.Name
        if ($null -eq $idx) { continue }
        $candidate = Get-SlotRunnerName -HostLabel $HostLabel -Name $poolDir.Name -Index $idx
        if ($candidate -eq $RunnerName) {
            $foundPoolName = $poolDir.Name
            $foundPoolDir = $poolDir.FullName
            $foundIndex = $idx
            break
        }
    }
    if ($foundPoolName) { break }
}

if (-not $foundPoolName) {
    Invoke-PoolDie "no runner slot found for '$RunnerName' on this host"
}

$repo = Get-PoolRepo -PoolDir $foundPoolDir
if (-not $repo) {
    # Not knowing the repo isn't just a busy-check problem: Start-Slot
    # below needs it to re-register the slot, -Force or not.
    if ($Force) {
        Invoke-PoolDie "can't tell which repo pool '$foundPoolName' serves, so can't restart $RunnerName"
    }
    Invoke-PoolRefuse "can't tell which repo pool '$foundPoolName' serves, so can't check $RunnerName is idle"
}

if (-not $Force) {
    # Ask about this one slot first: a direct match is the strongest
    # signal. Only fall back to "does anything in the pool match at all"
    # (the way pools.sh's restart_runner does via pool_runner_counts) when
    # this slot itself isn't currently registered -- normal between jobs,
    # or when it's stuck failing to register, which restarting it is for.
    $single = Get-RunnerMatchStats -Repo $repo -RunnerNames @($RunnerName)
    if (-not $single.Known) {
        Invoke-PoolRefuse "could not ask GitHub whether $RunnerName is busy"
    }
    if ($single.Matched -gt 0) {
        if ($single.Busy -gt 0) {
            Invoke-PoolRefuse "$RunnerName is running a job; restarting would cancel it"
        }
    } else {
        $slotDirs = Get-PoolSlotDirs -PoolDir $foundPoolDir
        $poolRunnerNames = @()
        foreach ($slotDir in $slotDirs) {
            $idx = Get-SlotIndex -SlotName $slotDir.Name
            $poolRunnerNames += (Get-SlotRunnerName -HostLabel $HostLabel -Name $foundPoolName -Index $idx)
        }
        $poolStats = Get-RunnerMatchStats -Repo $repo -RunnerNames $poolRunnerNames
        if ($poolStats.Matched -eq 0) {
            Invoke-PoolRefuse "no runner on GitHub matches any of pool '$foundPoolName's slots, so can't confirm $RunnerName is idle"
        }
    }
}

# Already confirmed idle (or -Force): drop straight to a forced local stop
# rather than waiting out Stop-Slot's TimeoutSeconds, since an ephemeral
# runner that isn't mid-job has no reason to exit on its own -- it just sits
# listening for the next job until killed. See windows/README.md.
[void](Stop-Slot -SlotDir (Join-Path $foundPoolDir "slot-$foundIndex") -SlotLabel "$foundPoolName slot-$foundIndex" -Force -TimeoutSeconds $TimeoutSeconds)

Start-Slot -PoolDir $foundPoolDir -Name $foundPoolName -Index $foundIndex -Repo $repo -PatFile $PatFile `
    -HostLabel $HostLabel -WindowsDir $PSScriptRoot -RunnerVersion $RunnerVersion -Arch $Arch

Write-Host "Restart-RunnerSlot: $RunnerName restarted"
