<#
.SYNOPSIS
    Shared library, dot-sourced by windows-pools.ps1, Start-RunnerPool.ps1,
    Stop-RunnerPool.ps1 and Restart-RunnerSlot.ps1: per-slot start/stop
    primitives, windows-pools.conf parsing, and GitHub-runner matching --
    the Windows analogue of the plumbing functions in pools.sh (project(),
    conf_line(), repo_runners(), runner_for(), pool_runner_counts(),
    require_idle(), json_str()).

.NOTES
    PowerShell 5.1 compatible on purpose: this is dot-sourced synchronously
    into windows-pools.ps1, which a 5.1-only host may be running. No
    ternary, no `??`/`?.`, no `&&`/`||` between commands, no
    `ConvertFrom-Json -AsHashtable`, no `ForEach-Object -Parallel`. Verify
    with:
      [System.Management.Automation.Language.Parser]::ParseFile(
        'windows\PoolSlot.ps1', [ref]$null, [ref]$errors)
    under Windows PowerShell 5.1 after editing.
#>

# Exit code stop/restart/restart-runner use when they refuse to act because
# a runner looks busy, or busy-ness can't be established. Distinct from 1
# so a caller (dashboard, script) can offer -Force instead of treating it
# as a hard error. Mirrors pools.sh's EXIT_REFUSED.
$Script:EXIT_REFUSED = 3

function Write-PoolError {
    param([Parameter(Mandatory)][string]$Message)
    [Console]::Error.WriteLine("windows-pools: $Message")
}

# Prints <Message> to stderr and exits 1. Mirrors pools.sh's die().
function Invoke-PoolDie {
    param([Parameter(Mandatory)][string]$Message)
    Write-PoolError $Message
    exit 1
}

# Prints <Message> to stderr and exits EXIT_REFUSED. Mirrors pools.sh's
# refuse().
function Invoke-PoolRefuse {
    param([Parameter(Mandatory)][string]$Message)
    Write-PoolError "$Message -- -Force to do it anyway"
    exit $Script:EXIT_REFUSED
}

# Every non-blank, non-comment line of windows-pools.conf as an object with
# Name/Repo/Count (Count defaults to 2 when the column is missing, same
# default as pools.conf's conf_line()).
function Get-PoolConfLines {
    param([Parameter(Mandatory)][string]$ConfPath)
    $lines = New-Object System.Collections.ArrayList
    if (-not (Test-Path $ConfPath)) { return $lines.ToArray() }
    foreach ($raw in Get-Content $ConfPath) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }
        $parts = [System.Text.RegularExpressions.Regex]::Split($line, '\s+')
        if ($parts.Count -lt 2) { continue }
        $count = 2
        if ($parts.Count -ge 3 -and $parts[2] -match '^\d+$') { $count = [int]$parts[2] }
        [void]$lines.Add([PSCustomObject]@{ Name = $parts[0]; Repo = $parts[1]; Count = $count })
    }
    return $lines.ToArray()
}

# The windows-pools.conf line for <Name>, or $null if it isn't declared.
function Get-PoolConfLine {
    param([Parameter(Mandatory)][string]$ConfPath, [Parameter(Mandatory)][string]$Name)
    foreach ($l in (Get-PoolConfLines -ConfPath $ConfPath)) {
        if ($l.Name -eq $Name) { return $l }
    }
    return $null
}

# Sets <Name>'s count in windows-pools.conf to <Count>, leaving every other
# line -- comments included -- as it was. Returns the count the line had
# before, or $null if it already said <Count> -- or if <Name> has no line
# at all, so check that with Get-PoolConfLine first (scale does, before it
# touches any slot). The Windows analogue of
# pools.sh's conf_set_count(): start and restart read the count from here,
# so without it the next one would quietly undo a scale.
function Set-PoolConfCount {
    param(
        [Parameter(Mandatory)][string]$ConfPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Count
    )
    $lines = @(Get-Content -Path $ConfPath)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $trimmed = $lines[$i].Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        $parts = [System.Text.RegularExpressions.Regex]::Split($trimmed, '\s+')
        if ($parts.Count -lt 2 -or $parts[0] -ne $Name) { continue }
        # Same default as Get-PoolConfLines: no count column reads as 2.
        $old = 2
        if ($parts.Count -ge 3 -and $parts[2] -match '^\d+$') { $old = [int]$parts[2] }
        if ($old -eq $Count) { return $null }
        $m = [System.Text.RegularExpressions.Regex]::Match($lines[$i], '^(\s*\S+\s+\S+\s+)(\S+)(.*)$')
        if ($m.Success) {
            # Keep anything after the count where it was: take the change in
            # width out of, or add it to, the gap after the count.
            $rest = $m.Groups[3].Value
            $diff = "$Count".Length - $m.Groups[2].Value.Length
            if ($diff -lt 0 -and $rest) {
                $rest = (' ' * (-$diff)) + $rest
            } elseif ($diff -gt 0 -and $rest -match '^(\s+)' -and $Matches[1].Length -gt $diff) {
                $rest = $rest.Substring($diff)
            }
            $lines[$i] = $m.Groups[1].Value + "$Count" + $rest
        } else {
            $lines[$i] = $lines[$i].TrimEnd() + " $Count"
        }
        $tmpPath = "$ConfPath.tmp"
        Set-Content -Path $tmpPath -Value $lines
        Move-Item -Force -Path $tmpPath -Destination $ConfPath
        return $old
    }
    return $null
}

# Appends a windows-pools.conf line declaring <Name> for <Repo> at <Count>,
# creating the file if it isn't there -- the Windows analogue of pools.sh's
# declare. The caller checks <Name> isn't declared already. Rewritten
# whole, rather than appended to, so a last line with no newline can't
# have this one glued onto it.
function Add-PoolConfLine {
    param(
        [Parameter(Mandatory)][string]$ConfPath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Count
    )
    $lines = @()
    if (Test-Path $ConfPath) { $lines = @(Get-Content -Path $ConfPath) }
    $tmpPath = "$ConfPath.tmp"
    Set-Content -Path $tmpPath -Value ($lines + ('{0,-16} {1,-28} {2}' -f $Name, $Repo, $Count))
    Move-Item -Force -Path $tmpPath -Destination $ConfPath
}

# The repo a pool directory says it serves, read back from .repo (written by
# Start-Slot/Start-RunnerPool.ps1), or $null if there's no pool directory or
# no .repo file yet.
function Get-PoolRepo {
    param([Parameter(Mandatory)][string]$PoolDir)
    $repoFile = Join-Path $PoolDir '.repo'
    if (-not (Test-Path $repoFile)) { return $null }
    $repo = (Get-Content -Raw $repoFile).Trim()
    if (-not $repo) { return $null }
    return $repo
}

# Every slot-* directory under a pool directory, sorted, or an empty array
# if the pool directory doesn't exist.
function Get-PoolSlotDirs {
    param([Parameter(Mandatory)][string]$PoolDir)
    if (-not (Test-Path $PoolDir)) { return @() }
    $slots = Get-ChildItem -Path $PoolDir -Directory -Filter 'slot-*' -ErrorAction SilentlyContinue
    if (-not $slots) { return @() }
    return @($slots | Sort-Object Name)
}

# The trailing integer in "slot-<N>", or $null if the name doesn't match.
function Get-SlotIndex {
    param([Parameter(Mandatory)][string]$SlotName)
    if ($SlotName -match '^slot-(\d+)$') { return [int]$Matches[1] }
    return $null
}

# Whether a slot's registered background process is alive, per its .pid
# file.
function Test-SlotRunning {
    param([Parameter(Mandatory)][string]$SlotDir)
    $pidFile = Join-Path $SlotDir '.pid'
    if (-not (Test-Path $pidFile)) { return $false }
    $slotPid = Get-Content $pidFile -ErrorAction SilentlyContinue
    if (-not $slotPid) { return $false }
    $proc = Get-Process -Id $slotPid -ErrorAction SilentlyContinue
    return [bool]$proc
}

# The GitHub runner name a slot registers under -- has to match
# Start-RunnerPool.ps1's "$HostLabel-$env:COMPUTERNAME-$Name-slot$i" exactly,
# since that's the only handle GitHub gives back to say which slot a runner
# is.
function Get-SlotRunnerName {
    param(
        [Parameter(Mandatory)][string]$HostLabel,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Index
    )
    return "$HostLabel-$env:COMPUTERNAME-$Name-slot$Index"
}

# Every GitHub Actions runner registered for <Repo>, as an array of
# PSCustomObject (name/status/busy/labels/...), or $null if `gh` is missing
# or the API call fails -- "unknown" has to stay distinguishable from
# "zero runners", the same distinction pools.sh's repo_runners() makes by
# failing outright instead of printing nothing.
function Get-GhRunnersForRepo {
    param([Parameter(Mandatory)][string]$Repo)
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }
    $all = New-Object System.Collections.ArrayList
    $page = 1
    while ($true) {
        $json = gh api "repos/$Repo/actions/runners?per_page=100&page=$page" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $json) {
            if ($page -eq 1) { return $null }
            break
        }
        $obj = $null
        try { $obj = $json | ConvertFrom-Json } catch { $obj = $null }
        if (-not $obj) {
            if ($page -eq 1) { return $null }
            break
        }
        if (-not $obj.runners -or @($obj.runners).Count -eq 0) { break }
        foreach ($r in @($obj.runners)) { [void]$all.Add($r) }
        if (@($obj.runners).Count -lt 100) { break }
        $page++
    }
    # The leading comma is load-bearing: a bare `return $all.ToArray()`
    # collapses to $null at the call site when the repo genuinely has zero
    # runners (a real PowerShell gotcha -- an empty array returned from a
    # function unrolls to nothing on the pipeline, which an assignment like
    # `$runners = Get-GhRunnersForRepo ...` then sees as $null). That would
    # make Get-RunnerMatchStats treat "GitHub said zero runners" the same
    # as "GitHub could not be asked", misreporting Known as $false. The
    # comma operator wraps the array so it survives the return as one
    # object instead of being enumerated away.
    return ,$all.ToArray()
}

# The entry in <Runners> (as returned by Get-GhRunnersForRepo) whose .name
# matches <Name>, or $null. PowerShell string -eq is already
# culture-invariant case-insensitive, which is what's needed here: GitHub
# capitalises label names on the way back, and names it hands back have
# been seen to vary in case too, so match loosely rather than trust the
# case this host sent at registration time.
function Find-RunnerByName {
    param($Runners, [Parameter(Mandatory)][string]$Name)
    foreach ($r in $Runners) {
        if ($r.name -eq $Name) { return $r }
    }
    return $null
}

# Matches <RunnerNames> (one pool's, or one slot's, worth of expected GitHub
# runner names) against <Repo>'s actual runners. Returns an object with:
#   Known   -- $true if GitHub could be asked at all
#   Matched -- how many of <RunnerNames> have a registered GitHub runner
#   Online  -- how many of the matched runners are status=online
#   Busy    -- how many of the matched runners are busy=true
#   ByName  -- hashtable, matched name -> runner object
# Mirrors pools.sh's pool_runner_counts()/runner_for(), generalised to also
# serve list -Json's per-member detail (ByName).
function Get-RunnerMatchStats {
    param([string]$Repo, [string[]]$RunnerNames)
    $result = [PSCustomObject]@{
        Known   = $false
        Matched = 0
        Online  = 0
        Busy    = 0
        ByName  = @{}
    }
    if (-not $Repo) { return $result }
    $runners = Get-GhRunnersForRepo -Repo $Repo
    if ($null -eq $runners) { return $result }
    $result.Known = $true
    $map = @{}
    foreach ($rn in $RunnerNames) {
        $m = Find-RunnerByName -Runners $runners -Name $rn
        if ($m) {
            $result.Matched = $result.Matched + 1
            if ($m.status -eq 'online') { $result.Online = $result.Online + 1 }
            if ($m.busy) { $result.Busy = $result.Busy + 1 }
            $map[$rn] = $m
        }
    }
    $result.ByName = $map
    return $result
}

# Exits EXIT_REFUSED unless GitHub confirms none of <RunnerNames> (one
# pool's slots, or a single slot) is busy. Advisory, not a lock: a runner
# can still pick up a job right after this. Mirrors pools.sh's
# require_idle(), generalised over both the whole-pool and single-slot
# cases (stop/restart vs restart-runner) via the same RunnerNames list.
#
# -HasSlots must reflect whether the pool has ANY slot directory on disk,
# not just ones whose name parsed into a runner name -- RunnerNames only
# ever holds the ones that did (see Get-PoolRunnerNames). Skipping the
# check on an empty RunnerNames list, full stop, would treat "every slot
# directory's name is malformed" the same as "there is genuinely nothing
# here", and the former can still have a live, possibly mid-job process
# behind that malformed name; only the latter is actually safe to skip.
function Assert-RunnersIdle {
    param(
        [Parameter(Mandatory)][string]$Label,
        [string]$Repo,
        [string[]]$RunnerNames,
        # Only these of RunnerNames count as busy -- for scale, which stops
        # some of a pool's slots rather than all of them. RunnerNames stays
        # the whole pool, so the "nothing matches" check below keeps meaning
        # what it means for stop.
        [string[]]$BusyAmong,
        [switch]$HasSlots,
        [switch]$Force
    )
    if ($Force) { return }
    if (-not $HasSlots) { return }
    if (-not $Repo) {
        Invoke-PoolRefuse "can't tell which repo $Label serves, so can't check it is idle"
    }
    $stats = Get-RunnerMatchStats -Repo $Repo -RunnerNames $RunnerNames
    if (-not $stats.Known) {
        Invoke-PoolRefuse "could not ask GitHub whether $Label is busy"
    }
    # A slot between jobs is briefly unregistered, but a running job always
    # has a registration -- so if none of the pool's slots matches a
    # runner, the likelier story is that the name-matching broke, and a
    # broken match would hide a busy runner.
    if ($stats.Matched -eq 0) {
        Invoke-PoolRefuse "no runner on GitHub matches any of $Label's slots, so can't confirm it is idle"
    }
    $busy = $stats.Busy
    if ($PSBoundParameters.ContainsKey('BusyAmong')) {
        $busy = 0
        foreach ($n in $BusyAmong) {
            if ($stats.ByName.ContainsKey($n) -and $stats.ByName[$n].busy) { $busy = $busy + 1 }
        }
    }
    if ($busy -gt 0) {
        Invoke-PoolRefuse "$Label has $busy busy runner(s); this would cancel their jobs"
    }
}

# Kills <SlotPid> and everything it started. runner-loop.ps1 runs run.cmd,
# and run.cmd the Runner.Listener, as child processes, and Windows doesn't
# take children down with their parent: Stop-Process on the loop alone
# leaves a listener that is still registered and still takes jobs, for a
# slot this host now counts as stopped. taskkill /T walks the tree.
function Stop-SlotProcessTree {
    param([Parameter(Mandatory)][string]$SlotPid)
    # 'Continue' for this call only: under 'Stop', Windows PowerShell 5.1
    # turns a native command's stderr line into a terminating error, and
    # taskkill writes one for any process in the tree that already exited.
    $ErrorActionPreference = 'Continue'
    # taskkill's exit code would otherwise become the caller's
    # $LASTEXITCODE, and windows-pools.ps1 reads that after the next script
    # it runs as that script's own failure. Put back what was there rather
    # than zero it, so the kill is as invisible to the caller as the
    # Stop-Process it replaced, and can't wipe out a code the caller hasn't
    # looked at yet.
    $savedExitCode = $global:LASTEXITCODE
    & taskkill.exe /PID $SlotPid /T /F *> $null
    $global:LASTEXITCODE = $savedExitCode
    if (Get-Process -Id $SlotPid -ErrorAction SilentlyContinue) {
        Stop-Process -Id $SlotPid -Force -ErrorAction SilentlyContinue
    }
}

# Stops one slot's background runner-loop.ps1: drops the .stop file so a
# job in progress is left to finish, waits up to TimeoutSeconds, then
# either force-kills (-Force) or gives up and reports still-running.
# Returns $true if the slot ended up stopped (or was never running), $false
# if it's still running. The Windows analogue of the per-container part of
# `docker compose down` -- refactored out of Stop-RunnerPool.ps1's loop
# body so Restart-RunnerSlot.ps1 can restart exactly one slot without
# touching its siblings.
function Stop-Slot {
    param(
        [Parameter(Mandatory)][string]$SlotDir,
        [Parameter(Mandatory)][string]$SlotLabel,
        [switch]$Force,
        [int]$TimeoutSeconds = 60
    )
    $pidFile = Join-Path $SlotDir '.pid'
    $stopFile = Join-Path $SlotDir '.stop'

    New-Item -ItemType File -Force -Path $stopFile | Out-Null

    if (-not (Test-Path $pidFile)) {
        Write-Host "Stop-Slot: $SlotLabel has no .pid file, nothing to signal"
        return $true
    }
    $slotPid = Get-Content $pidFile
    $proc = Get-Process -Id $slotPid -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Host "Stop-Slot: $SlotLabel pid $slotPid is not running"
        Remove-Item -Force $pidFile
        return $true
    }

    Write-Host "Stop-Slot: signalled $SlotLabel (pid $slotPid), waiting up to ${TimeoutSeconds}s"
    $waited = 0
    while ((Get-Process -Id $slotPid -ErrorAction SilentlyContinue) -and $waited -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 2
        $waited = $waited + 2
    }

    if (Get-Process -Id $slotPid -ErrorAction SilentlyContinue) {
        if ($Force) {
            Write-Host "Stop-Slot: $SlotLabel still running after ${TimeoutSeconds}s, forcing (-Force) -- any in-progress job is cut off"
            Stop-SlotProcessTree -SlotPid $slotPid
        } else {
            Write-Host "Stop-Slot: $SlotLabel still running after ${TimeoutSeconds}s (likely mid-job) -- pass -Force to kill it, or wait longer"
            return $false
        }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $pidFile
    return $true
}

# Starts one slot: installs the runner binary if needed, then launches
# runner-loop.ps1 as a hidden background process and records its pid.
# Skips silently if the slot is already running. Refactored out of
# Start-RunnerPool.ps1's loop body for the same reason as Stop-Slot.
function Start-Slot {
    param(
        [Parameter(Mandatory)][string]$PoolDir,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$PatFile,
        [Parameter(Mandatory)][string]$HostLabel,
        [Parameter(Mandatory)][string]$WindowsDir,
        [string]$RunnerVersion = '2.337.0',
        [ValidateSet('x64', 'arm64')] [string]$Arch = 'x64'
    )
    $slot = Join-Path $PoolDir "slot-$Index"
    $pidFile = Join-Path $slot '.pid'
    $stopFile = Join-Path $slot '.stop'
    $logDir = Join-Path $PoolDir 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    if (Test-Path $pidFile) {
        $existingPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
            Write-Host "Start-Slot: $Name slot-$Index already running (pid $existingPid), skipping"
            return
        }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $stopFile

    & (Join-Path $WindowsDir 'Install-Runner.ps1') -Path $slot -Version $RunnerVersion -Arch $Arch

    $runnerName = Get-SlotRunnerName -HostLabel $HostLabel -Name $Name -Index $Index
    $labels = "self-hosted,windows,$Arch,$HostLabel"
    $log = Join-Path $logDir "slot-$Index.log"

    # Point setup-python/setup-node/etc at a persistent, pre-populated tool
    # cache (see Install-PythonToolCache.ps1) instead of the default
    # location under this slot's own _work, which gets wiped every job.
    # Both var names are set because different actions/toolkit versions
    # read one or the other. Set here (rather than by each caller) so every
    # path that (re)starts a slot -- the pool-level loop in
    # Start-RunnerPool.ps1 and the single-slot path in
    # Restart-RunnerSlot.ps1 -- gets it; Start-Process below inherits it
    # from this process's environment.
    $toolCacheDir = Join-Path (Split-Path -Parent $WindowsDir) 'windows\toolcache'
    $env:RUNNER_TOOL_CACHE = $toolCacheDir
    $env:AGENT_TOOLSDIRECTORY = $toolCacheDir

    # See Start-RunnerPool.ps1's header comment for why this falls back to
    # powershell.exe, and what that fallback requires of runner-loop.ps1.
    $shell = 'powershell'
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { $shell = 'pwsh' }
    $psi = @{
        FilePath               = $shell
        ArgumentList           = @(
            '-NoProfile', '-File', (Join-Path $WindowsDir 'runner-loop.ps1'),
            '-RunnerDir', $slot,
            '-Repo', $Repo,
            '-PatFile', $PatFile,
            '-RunnerName', $runnerName,
            '-Labels', $labels,
            '-StopFile', $stopFile
        )
        WindowStyle            = 'Hidden'
        RedirectStandardOutput = $log
        RedirectStandardError  = "$log.err"
        PassThru               = $true
    }
    $proc = Start-Process @psi
    Set-Content -Path $pidFile -Value $proc.Id
    Write-Host "Start-Slot: $Name slot-$Index started (pid $($proc.Id)), logging to $log"
}

# Builds one pool's JSON-ready object for `windows-pools.ps1 list -Json`,
# matching pools.sh's cmd_list_json shape field-for-field except "project"
# (kept, equal to Name, for shape-compatibility -- there's no compose
# project concept here) and "label" (always $null -- windows-pools.conf has
# no extra-label column) and the addition of "os":"windows". Queries GitHub
# at most once per pool.
function Get-PoolStatusObject {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RunnersRoot,
        [Parameter(Mandatory)][string]$ConfPath,
        [Parameter(Mandatory)][string]$HostLabel
    )
    $confLine = Get-PoolConfLine -ConfPath $ConfPath -Name $Name
    $managed = $false
    $repo = $null
    $desired = $null
    if ($confLine) {
        $managed = $true
        $repo = $confLine.Repo
        $desired = $confLine.Count
    }

    $poolDir = Join-Path $RunnersRoot $Name
    $slotDirs = Get-PoolSlotDirs -PoolDir $poolDir

    if (-not $repo) { $repo = Get-PoolRepo -PoolDir $poolDir }

    $runnerNames = @()
    $members = New-Object System.Collections.ArrayList
    $total = 0
    $running = 0

    $known = $false
    $stats = $null
    if ($slotDirs.Count -eq 0) {
        $known = $true
    } elseif ($repo) {
        foreach ($slotDir in $slotDirs) {
            $idx = Get-SlotIndex -SlotName $slotDir.Name
            # Get-SlotRunnerName's -Index is Mandatory/[int]: a stray
            # slot-* directory whose name isn't "slot-<digits>" (a
            # partially-failed Start-Slot, or one made by hand) would
            # otherwise throw here and abort list -Json for the whole
            # host. Skip it, same as windows-pools.ps1's own
            # Get-PoolRunnerNames does.
            if ($null -eq $idx) { continue }
            $runnerNames += (Get-SlotRunnerName -HostLabel $HostLabel -Name $Name -Index $idx)
        }
        $stats = Get-RunnerMatchStats -Repo $repo -RunnerNames $runnerNames
        $known = $stats.Known
    }

    foreach ($slotDir in $slotDirs) {
        $idx = Get-SlotIndex -SlotName $slotDir.Name
        if ($null -eq $idx) { continue }
        $total = $total + 1
        $isRunning = Test-SlotRunning -SlotDir $slotDir.FullName
        if ($isRunning) { $running = $running + 1 }

        $runnerName = Get-SlotRunnerName -HostLabel $HostLabel -Name $Name -Index $idx
        $runnerObj = $null
        if ($known -and $stats -and $stats.ByName.ContainsKey($runnerName)) {
            $m = $stats.ByName[$runnerName]
            $runnerObj = [PSCustomObject]@{
                name   = $m.name
                status = $m.status
                busy   = [bool]$m.busy
            }
        }
        $state = 'exited'
        $status = 'not running'
        if ($isRunning) { $state = 'running'; $status = 'running' }

        [void]$members.Add([PSCustomObject]@{
            container = $runnerName
            id        = "$idx"
            state     = $state
            status    = $status
            runner    = $runnerObj
        })
    }

    $runnersField = $null
    if ($known) {
        $online = 0
        $busy = 0
        if ($stats) { $online = $stats.Online; $busy = $stats.Busy }
        $runnersField = [PSCustomObject]@{ online = $online; busy = $busy }
    }

    return [PSCustomObject]@{
        name       = $Name
        project    = $Name
        repo       = $repo
        managed    = $managed
        desired    = $desired
        label      = $null
        containers = [PSCustomObject]@{ total = $total; running = $running }
        runners    = $runnersField
        members    = $members.ToArray()
        os         = 'windows'
    }
}
