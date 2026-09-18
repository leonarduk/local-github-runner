<#
.SYNOPSIS
    Bookkeeping for tests that spawn real processes: track what you
    spawned, kill only that, and never trust a bare PID. Dot-source it:
    `. (Join-Path $PSScriptRoot 'ProcessTracking.ps1')`.

.NOTES
    A file of its own, rather than a few helpers inside the one suite that
    needed them first, so that tests\process_tracking_test.ps1 can check
    these rules directly. The suite they came from cannot: the condition
    that broke it is two runs sharing a machine, which no single run can
    arrange on demand.

    The rules, and why (issue #123):

    A PID is not an identity. Windows hands a freed PID to a new process
    quickly, so "the PID I recorded earlier" and "the process I started
    earlier" stop being the same thing the moment that process exits.
    tests\windows_pools_test.ps1 force-killed every PID it had ever
    recorded on the way out, most of whose processes had long exited (the
    stand-ins Stop-Slot already killed, and the runner-loop.ps1 slots that
    exit at once on an empty pat.secret). Run two copies of it at once --
    pwsh and 5.1 side by side, which is a normal afternoon on a developer's
    machine -- and the one finishing killed the other's live slot
    processes, which then failed checks about its own slots. On a CI runner,
    one suite per fresh VM, it passed every time.

    So: every spawned process is tracked as a Process object with its
    handle held open, never as a number. Windows will not reuse a PID while
    a handle to that process is open, which makes the object's identity
    good for as long as the run holds it, and Stop-TrackedProcesses kills
    only tracked processes that have not already exited.

    A PID read back from a file (a slot's .pid) is the one case where a
    number is all there is. Get-StandInCommand's process cannot help there
    either -- the process was started by something else. Register-SlotPidFile
    takes it, but only trusts it if the process it names started before the
    file naming it was written, which a process that merely inherited the
    number cannot have done.
#>

# Added to by Register-Spawned and Register-SlotPidFile. Stop-TrackedProcesses
# walks it and never empties it: a process it killed still belongs to this
# run, and a run that cleans up twice (a failure on the way out of one that
# already tidied up) must find the same list, not a shorter one. Dot-sourcing
# puts it in the caller's script scope, which is where the functions below
# resolve it from.
$script:TrackedProcesses = New-Object System.Collections.ArrayList

# What a stand-in process should run: wait for the process that started it
# (by default this one) to exit, and go away with it. Not a fixed
# Start-Sleep, which a slow run can outlast -- a stand-in that expires
# mid-run is a slot the test still expects to be running. It also means a
# run that is killed before it can clean up still leaves nothing behind.
function Get-StandInCommand {
    param([int]$ProcessId = $PID)
    return "[System.Diagnostics.Process]::GetProcessById($ProcessId).WaitForExit()"
}

# Tracks a process this run started. Reading .Handle opens the handle and
# keeps it for the object's lifetime, which is what pins the PID.
function Register-Spawned {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)
    $null = $Process.Handle
    [void]$script:TrackedProcesses.Add($Process)
    return $Process
}

# Tracks the process a .pid file names, for the processes this run caused
# but did not start itself -- a slot launched by windows-pools.ps1 in a
# child process, whose Process object we never see. By the time this reads
# one, that process may have exited and the PID gone to something else, so
# only a process that already existed when the file was written is ours.
# Returns the Process, or $null if there is nothing of ours to track.
function Register-SlotPidFile {
    param([Parameter(Mandatory)][string]$PidFile)
    # A digits-only read, not just a non-empty one: Set-Content creates a
    # file before it writes to it, so a .pid read the instant it appears
    # can come back empty -- which is a parameter-binding failure no
    # -ErrorAction suppresses, or, once PowerShell coerces it, PID 0: the
    # System Idle Process, which is always running and never exits.
    $slotPid = "$(Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)".Trim()
    if ($slotPid -notmatch '^\d+$') { return $null }
    $proc = Get-Process -Id ([int]$slotPid) -ErrorAction SilentlyContinue
    if (-not $proc) { return $null }
    # The handle first and the start time second, in that order: opening
    # the handle is what pins the PID, so a process that survives both
    # checks cannot have been replaced between them. The file's own time is
    # read last for the same reason: a .pid rewritten under us (a slot
    # restarting, say) can only make this stricter, and the strict answer
    # here is to leave a process alone, never to kill one that isn't ours.
    try { $null = $proc.Handle } catch { return $null }
    if ($proc.StartTime -gt (Get-Item $PidFile).LastWriteTime) { return $null }
    [void]$script:TrackedProcesses.Add($proc)
    return $proc
}

# Kills every tracked process that is still running, and nothing else.
# Safe to call more than once, and on processes that have since exited on
# their own -- which most of them have.
function Stop-TrackedProcesses {
    foreach ($proc in $script:TrackedProcesses) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
    }
}
