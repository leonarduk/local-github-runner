<#
.SYNOPSIS
    Runs one tests\*_test.ps1 several times at once, staggered, under both
    `powershell` (5.1) and `pwsh` (7+), and fails if any run fails.

.EXAMPLE
    pwsh -NoProfile -File .\.github\scripts\Invoke-OverlappingPoolTests.ps1
    pwsh -NoProfile -File .\.github\scripts\Invoke-OverlappingPoolTests.ps1 -Runs 2 -StaggerSeconds 10

.NOTES
    Why this exists next to Invoke-PowerShellTests.ps1, which already runs
    the same file under both shells: it runs one suite at a time on a
    fresh VM, and a whole class of bug in a test that spawns real
    processes only shows up when two runs of it share a machine. Issue
    #123 was exactly that -- the suite tracked the processes it spawned as
    bare PIDs and force-killed every one of them on the way out, including
    PIDs whose process had long exited. Windows hands a freed PID to a new
    process quickly, so a finishing run killed a *concurrent* run's live
    slot processes, and that run then failed a check about its own slots.
    It passed in CI every time and failed on a developer's machine, where
    two shells' runs overlap.

    One suite per run is deliberate: this is a concurrency check, not a
    second copy of the test matrix. Point it at the suite that spawns
    processes.

    A run whose log this script cannot read, or a set of runs that never
    actually overlapped, is a failure and not a pass: a suite that got
    fast enough to finish before the next one starts would otherwise turn
    this into a check that runs six times and tests nothing.
#>
[CmdletBinding()]
param(
    # Relative to the repo root.
    [string]$TestPath = 'tests\windows_pools_test.ps1',
    # Six, and 20s apart, is what reproduced #123 by hand: enough runs that
    # one is always finishing (and cleaning up) while others are mid-suite.
    [int]$Runs = 6,
    [int]$StaggerSeconds = 20,
    [int]$TimeoutMinutes = 12
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$test = Join-Path $root $TestPath
if (-not (Test-Path $test)) { throw "no such test: $test" }

# Both shells, alternating, so each is represented however many runs are
# asked for. Resolved to full paths: `pwsh` and `powershell` both resolve
# from either shell on a GitHub windows runner, but the .Path is what ends
# up in the log, and "which shell was that run?" is the first question a
# failure here raises.
$shells = @()
foreach ($name in 'pwsh', 'powershell') {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { $shells += $cmd.Path }
}
if ($shells.Count -eq 0) { throw 'neither pwsh nor powershell is on PATH' }
if ($shells.Count -eq 1) { Write-Host ("WARNING: only {0} is on PATH; running every copy under it" -f $shells[0]) }

$logDir = Join-Path ([System.IO.Path]::GetTempPath()) ("overlap_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

Write-Host ("Running {0} {1} times, {2}s apart, under: {3}" -f $TestPath, $Runs, $StaggerSeconds, ($shells -join ', '))
Write-Host ''

$started = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $Runs; $i++) {
    if ($i -gt 0) { Start-Sleep -Seconds $StaggerSeconds }
    $shell = $shells[$i % $shells.Count]
    $outLog = Join-Path $logDir ("run{0}.out.log" -f $i)
    $errLog = Join-Path $logDir ("run{0}.err.log" -f $i)
    # Separate files for the two streams: Windows PowerShell 5.1 refuses to
    # redirect both to the same one.
    $proc = Start-Process -FilePath $shell `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $test) `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
        -WindowStyle Hidden -PassThru
    Write-Host ("started run {0} (pid {1}) under {2} at {3:HH:mm:ss}" -f $i, $proc.Id, (Split-Path -Leaf $shell), [DateTime]::Now)
    [void]$started.Add([PSCustomObject]@{
            Index   = $i
            Shell   = (Split-Path -Leaf $shell)
            Proc    = $proc
            OutLog  = $outLog
            ErrLog  = $errLog
            Start   = [DateTime]::Now
            End     = [DateTime]::MinValue
            # Whether End is the process's own exit time rather than the
            # moment this script got round to looking.
            EndIsExact = $false
            Code    = $null
        })
}

# One deadline for all of them, set once the last run has been started, not
# a budget each: six runs of a suite that hangs are still one wait, and the
# job's own timeout-minutes has to cover the staggering plus this, not
# $Runs times this.
$deadline = [DateTime]::Now.AddMinutes($TimeoutMinutes)
foreach ($run in $started) {
    $left = [int]($deadline - [DateTime]::Now).TotalMilliseconds
    if ($left -lt 0) { $left = 0 }
    if ($run.Proc.WaitForExit($left)) {
        $run.Code = $run.Proc.ExitCode
    } else {
        # Killed rather than left behind: the runs share this machine, and
        # a hung suite still holding slot processes would outlive the job.
        try { $run.Proc.Kill() } catch { }
        $run.Code = 'timed out'
    }
    # When the run ended, not when this loop got round to noticing: the
    # runs are waited on in the order they started, so "now" here is the
    # moment the *previous* run's wait returned, which would make every
    # pair of runs look like it overlapped.
    $run.End = [DateTime]::Now
    try {
        if ($run.Proc.HasExited -and $run.Proc.ExitTime -gt $run.Start) {
            $run.End = $run.Proc.ExitTime
            $run.EndIsExact = $true
        }
    } catch { }
}

# Did they actually overlap? Two runs overlap when one started before the
# other ended -- and only a run whose exact end time we have can show that.
# "Now" is an upper bound, always later than the run really ended, so a pair
# judged on it would claim an overlap this job never saw.
$overlapped = $false
foreach ($a in $started) {
    foreach ($b in $started) {
        if ($a.EndIsExact -and $a.Index -lt $b.Index -and $b.Start -lt $a.End) { $overlapped = $true }
    }
}

$failed = New-Object System.Collections.ArrayList
foreach ($run in $started) {
    $secs = [int]($run.End - $run.Start).TotalSeconds
    Write-Host ("::group::run {0} ({1}, exit {2}, {3}s)" -f $run.Index, $run.Shell, $run.Code, $secs)
    foreach ($log in $run.OutLog, $run.ErrLog) {
        if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host $_ } }
        else { Write-Host ("(no $log)") }
    }
    Write-Host '::endgroup::'
    if ($run.Code -ne 0) {
        [void]$failed.Add($run.Index)
        Write-Host ("FAIL  run {0} ({1}): exit {2}" -f $run.Index, $run.Shell, $run.Code)
    } else {
        Write-Host ("ok    run {0} ({1}), {2}s" -f $run.Index, $run.Shell, $secs)
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host ("{0} of {1} overlapping runs of {2} failed: run(s) {3}" -f $failed.Count, $Runs, $TestPath, ($failed -join ', '))
    exit 1
}
if (-not $overlapped) {
    Write-Host ("every run of {0} finished before the next one started, so nothing was tested concurrently -- lower -StaggerSeconds (currently {1}s)" -f $TestPath, $StaggerSeconds)
    exit 1
}

Write-Host ("{0} overlapping runs of {1} all passed." -f $Runs, $TestPath)
exit 0
