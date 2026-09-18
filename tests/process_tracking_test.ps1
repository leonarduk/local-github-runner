<#
.SYNOPSIS
    Exercises tests\ProcessTracking.ps1 -- the "track what you spawned,
    kill only that, and never trust a bare PID" rules that
    tests\windows_pools_test.ps1 relies on -- against real, harmless,
    locally-spawned processes. Nothing real is touched: no Docker, no
    GitHub, no network, no runner.

.NOTES
    Why this exists separately from windows_pools_test.ps1, where these
    helpers started: the bug they fix (issue #123) needed two runs of that
    suite sharing a machine and a PID handed on from one to the other, and
    a suite cannot arrange that for itself. What it *can* check is the
    rule that makes the bug impossible, which is what this file does --
    the same way, and for the same reason, that a unit test is worth more
    than waiting for the race to come back.

    The one thing here that cannot be checked from a test is the Windows
    behaviour the rule leans on: that a PID is not reused while a handle
    to its process is open. Forcing a PID to be reused takes a machine
    under real process churn, so this file does the next best thing and
    checks what a run must do about a PID that *has* been: refuse it. The
    stand-in for "this PID was handed on" is a process that started after
    the file naming it was written, which is exactly what a run sees when
    the slot it recorded has gone and something else holds the number.

    Run with `pwsh -File tests\process_tracking_test.ps1` or
    `powershell.exe -File tests\process_tracking_test.ps1`; CI runs both.
#>
$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("process_tracking_test_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

. (Join-Path $PSScriptRoot 'ProcessTracking.ps1')

$fails = 0
# Started deliberately untracked, and killed at the end: the point of
# several checks below is what Stop-TrackedProcesses does *not* do.
$loose = New-Object System.Collections.ArrayList

function Check {
    param([string]$Desc, [bool]$Got)
    if ($Got) { Write-Host "ok   $Desc" }
    else { Write-Host "FAIL $Desc"; $script:fails = $script:fails + 1 }
}

# A real background process that lives until this test process exits, the
# same stand-in windows_pools_test.ps1 uses for a slot. Untracked: each
# check below tracks what it means to track.
function Start-StandIn {
    param([string]$Command = (Get-StandInCommand))
    $shell = 'powershell'
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { $shell = 'pwsh' }
    $proc = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-Command', $Command) `
        -WindowStyle Hidden -PassThru
    [void]$loose.Add($proc)
    return $proc
}

try {
    # ---- a .pid file whose process is genuinely the one it names -------
    $minePidFile = Join-Path $tmp 'mine.pid'
    $mine = Start-StandIn
    Set-Content -Path $minePidFile -Value $mine.Id
    $tracked = Register-SlotPidFile $minePidFile
    Check 'a process that started before its .pid file was written is tracked' `
    ($null -ne $tracked -and $tracked.Id -eq $mine.Id)

    # ---- a .pid file whose PID has been handed on ---------------------
    # The real thing: the slot exited, Windows gave its number to
    # something else, and this run is about to decide whether to kill it.
    # Here the "something else" is a process that started after the file
    # was written, which is the one thing a process that inherited the
    # number always is.
    $reusedPidFile = Join-Path $tmp 'reused.pid'
    $stranger = Start-StandIn
    Set-Content -Path $reusedPidFile -Value $stranger.Id
    (Get-Item $reusedPidFile).LastWriteTime = $stranger.StartTime.AddSeconds(-5)
    Check 'a process that started after its .pid file was written is refused' `
    ($null -eq (Register-SlotPidFile $reusedPidFile))

    # ---- a .pid file caught mid-write ---------------------------------
    # Set-Content creates a file before it writes to it, so a .pid read
    # the instant it appears can come back empty. Nothing may be tracked
    # for it, and nothing may be thrown: an empty read is a
    # parameter-binding failure or, coerced, PID 0 -- the System Idle
    # Process, which is always running and never exits.
    foreach ($case in @(@{ Desc = 'empty'; Value = '' }, @{ Desc = 'whitespace-only'; Value = '   ' }, @{ Desc = 'not a number'; Value = 'pid-goes-here' })) {
        $partialPidFile = Join-Path $tmp ("partial-" + $case.Desc.Replace(' ', '-') + ".pid")
        Set-Content -Path $partialPidFile -Value $case.Value
        $threw = $false
        $got = $null
        try { $got = Register-SlotPidFile $partialPidFile } catch { $threw = $true }
        Check ("a .pid file that is " + $case.Desc + " is refused, without throwing") (-not $threw -and $null -eq $got)
    }

    # A .pid file whose process has since exited -- what every slot's .pid
    # file looks like by the end of a run. Written while that process was
    # still alive, so this is refused however far the corpse has got: this
    # run still holds a handle to it, which keeps the PID taken and can
    # keep Get-Process handing the process back, so being refused rests on
    # the exit itself and not on the PID having gone away. And if the
    # number has been handed on, whatever holds it now started after the
    # file was written, which is refused too.
    $gonePidFile = Join-Path $tmp 'gone.pid'
    $gone = Start-StandIn
    Set-Content -Path $gonePidFile -Value $gone.Id
    $gone.Kill()
    [void]$gone.WaitForExit(20000)
    Check 'a .pid file naming a process that has since exited is refused' `
    ($null -eq (Register-SlotPidFile $gonePidFile))

    # ---- what Stop-TrackedProcesses kills, and what it leaves ---------
    $doomed = Register-Spawned (Start-StandIn)
    $exitedEarly = Register-Spawned (Start-StandIn -Command 'exit 0')
    [void]$exitedEarly.WaitForExit(20000)
    $bystander = Start-StandIn
    Check 'a stand-in is still running before anything kills it' (-not $doomed.HasExited)

    Stop-TrackedProcesses
    Check 'Stop-TrackedProcesses kills a tracked process that is still running' ($doomed.WaitForExit(20000))
    Check 'Stop-TrackedProcesses leaves a process this run never tracked alone' (-not $bystander.HasExited)
    # Twice over, and over an already-exited process: Cleanup paths run on
    # the way out of a failed run too, where some of this is already dead.
    Stop-TrackedProcesses
    Check 'Stop-TrackedProcesses is safe to call again' ($doomed.HasExited -and -not $bystander.HasExited)

    # ---- the stand-in command itself ----------------------------------
    # It has to outlive a slow run (a fixed Start-Sleep does not) and die
    # with the run that started it (an orphan holding a PID is what the
    # next run trips over).
    $victimScript = Join-Path $tmp 'victim.ps1'
    Set-Content -Path $victimScript -Value 'Start-Sleep -Seconds 3'
    $shell = 'powershell'
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { $shell = 'pwsh' }
    $victim = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-File', $victimScript) -WindowStyle Hidden -PassThru
    [void]$loose.Add($victim)
    $standIn = Start-StandIn -Command (Get-StandInCommand -ProcessId $victim.Id)
    Start-Sleep -Seconds 1
    Check 'a stand-in keeps running while the process it waits on is alive' (-not $standIn.HasExited)
    [void]$victim.WaitForExit(60000)
    Check 'a stand-in exits once the process it waits on has exited' ($standIn.WaitForExit(60000))
} finally {
    Stop-TrackedProcesses
    foreach ($proc in $loose) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
    }
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}

if ($fails -gt 0) {
    Write-Host "$fails check(s) failed"
    exit 1
}
Write-Host 'all checks passed'
