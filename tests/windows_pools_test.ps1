<#
.SYNOPSIS
    Exercises windows-pools.ps1's PoolSlot.ps1 library and its list -Json /
    start / stop / restart / restart-runner commands against a fake `gh` on
    PATH and real (but harmless, locally-spawned) processes standing in for
    slots: no Docker daemon here to fake, and no Windows equivalent of it
    to touch, but nothing real -- no GitHub mutation, no actual runner
    registration, no network -- is touched either.

.NOTES
    Why a fake gh.cmd on PATH rather than an injectable -GhCommand
    parameter (the other option the issue floated): pools_test.sh already
    establishes "stub the external command on PATH" as this repo's pattern
    for testing against docker/gh, and PoolSlot.ps1's functions are already
    written as plain functions (not a class with injected dependencies), so
    threading a mock parameter through every call site (Get-GhRunnersForRepo,
    Get-RunnerMatchStats, Assert-RunnersIdle, Get-PoolStatusObject, ...)
    would touch more of the library than it would save. A fake gh.cmd also
    exercises the real page-loop and JSON parsing in Get-GhRunnersForRepo,
    which an injected closure would bypass.

    Slots are real background processes (a one-liner under powershell/pwsh
    that waits for this test process to exit), not mocked Get-Process
    calls: PowerShell can't shadow a cmdlet like Get-Process from a script
    the way bash lets you shadow a binary on PATH, and stubbing it out via
    module-scoped function overrides would risk masking a real bug in the
    PID-liveness check itself. A real, do-nothing process is simpler and
    safer than trying to fake process state.

    Every process this file spawns is tracked as a Process object with its
    handle held open, never as a bare PID, through
    tests\ProcessTracking.ps1 -- whose .NOTES has the whole story (issue
    #123): killing and liveness-checking by bare PID hit other things that
    had since taken the number, including a concurrent run's live slots.

    Network safety: Install-Runner.ps1 skips its download whenever
    <slot>\config.cmd already exists (see its own header), so every slot
    directory here is pre-seeded with a placeholder config.cmd. Any
    runner-loop.ps1 launched by a Start-Slot call in this file only ever
    runs against a pat.secret that is deliberately absent, so it fails on
    its first line (no PAT file) before making any network call.

    Run with `pwsh -File tests\windows_pools_test.ps1`, or
    `powershell.exe -File tests\windows_pools_test.ps1` where pwsh isn't on
    PATH -- both are exercised in CI; this file itself has no PS7-only
    syntax so either runs it.
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("windows_pools_test_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$fails = 0

# Register-Spawned / Register-SlotPidFile / Stop-TrackedProcesses, plus
# the command every stand-in process runs. See its .NOTES for why none of
# this works on bare PIDs; tests\process_tracking_test.ps1 checks the
# rules themselves, which this file, being a single run, cannot.
. (Join-Path $PSScriptRoot 'ProcessTracking.ps1')
$dummyCommand = Get-StandInCommand

function Cleanup {
    Stop-TrackedProcesses
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}

try {
    # ---- lay out a fake repo checkout under $tmp -----------------------
    $binDir = Join-Path $tmp 'bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null

    Copy-Item (Join-Path $repoRoot 'windows-pools.ps1') $tmp
    $winDir = Join-Path $tmp 'windows'
    New-Item -ItemType Directory -Force -Path $winDir | Out-Null
    foreach ($f in 'PoolSlot.ps1', 'Start-RunnerPool.ps1', 'Stop-RunnerPool.ps1', 'Restart-RunnerSlot.ps1', 'Install-Runner.ps1', 'runner-loop.ps1') {
        Copy-Item (Join-Path $repoRoot "windows\$f") $winDir
    }
    $runnersRoot = Join-Path $winDir 'runners'
    New-Item -ItemType Directory -Force -Path $runnersRoot | Out-Null
    $confPath = Join-Path $tmp 'windows-pools.conf'
    Set-Content -Path $confPath -Value @(
        '# name repo count'
        'worm   o/r    2'
        'idle   o/idle 1'
    )

    # ---- fake gh, as a PowerShell function on $env:PSModulePath -----------
    # Controlled by env vars, read fresh on every invocation:
    #   FAKE_GH_FAIL=1        -- simulate gh (or the API) failing
    #   FAKE_RUNNERS=<json>   -- JSON array of {name,status,busy} to return
    # Paginates honestly: returns FAKE_RUNNERS on page 1, empty on any
    # later page, matching how Get-GhRunnersForRepo asks.
    #
    # Not a gh.cmd/gh.bat shim on PATH: a real GitHub API URL contains an
    # unescaped `&` ("...?per_page=100&page=1"), and launching a .cmd/.bat
    # file goes through cmd.exe, which -- even though the argument arrives
    # as one properly-quoted PowerShell argument -- re-parses the whole
    # command line and treats that `&` as a command separator (a
    # long-standing Windows quirk: CreateProcess on a .bat/.cmd file wraps
    # the entire line in one pair of quotes for cmd.exe's /c, and cmd.exe's
    # own outer-quote-stripping re-exposes `&` before the batch file ever
    # sees its arguments). A PowerShell function, auto-loaded from a module
    # on $env:PSModulePath, is invoked directly by PowerShell with no shell
    # in between, so the argument -- `&` and all -- reaches it intact.
    $modulesDir = Join-Path $binDir 'Modules'
    $ghModuleDir = Join-Path $modulesDir 'gh'
    New-Item -ItemType Directory -Force -Path $ghModuleDir | Out-Null
    Set-Content -Path (Join-Path $ghModuleDir 'gh.psm1') -Value @'
function gh {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GhArgs)
    if ($env:FAKE_GH_FAIL -eq '1') { $global:LASTEXITCODE = 1; return }
    $global:LASTEXITCODE = 0
    # autoscale: one queued run (id 100) whenever FAKE_JOBS -- a JSON array
    # of {status,labels} -- is set, holding those jobs, in every repo.
    $all = $GhArgs -join ' '
    if ($all -match 'actions/runs\?status=queued' -and $env:FAKE_JOBS) { Write-Output '{"workflow_runs":[{"id":100}]}'; return }
    if ($all -match 'actions/runs\?status=') { Write-Output '{"workflow_runs":[]}'; return }
    if ($all -match '/jobs\?') { Write-Output "{`"jobs`":$($env:FAKE_JOBS)}"; return }
    $runners = '[]'
    if ($env:FAKE_RUNNERS) { $runners = $env:FAKE_RUNNERS }
    $isPage1 = $true
    # Anchored on `&` or start-of-string so it doesn't also match the
    # "page=100" inside "per_page=100".
    foreach ($a in $GhArgs) { if ($a -match '(?:^|&)page=(\d+)' -and $Matches[1] -ne '1') { $isPage1 = $false } }
    if ($isPage1) {
        Write-Output "{`"runners`":$runners}"
    } else {
        Write-Output '{"runners":[]}'
    }
    $global:LASTEXITCODE = 0
}
Export-ModuleMember -Function gh
'@
    Set-Content -Path (Join-Path $ghModuleDir 'gh.psd1') -Value @'
@{
    ModuleVersion = '1.0'
    RootModule = 'gh.psm1'
    FunctionsToExport = @('gh')
    GUID = 'b7f6e5a0-4b1a-4b1a-9b1a-000000000001'
    Author = 'windows_pools_test.ps1'
}
'@

    $env:PSModulePath = "$modulesDir;$env:PSModulePath"
    # A real gh.exe may also be on this machine's PATH (e.g. GitHub CLI
    # installed for other work) -- PowerShell only auto-loads a module's
    # function for an unresolved command name, and an Application match on
    # PATH already resolves it, so auto-loading never gets a chance here.
    # Import it explicitly instead: once loaded, a Function always outranks
    # an Application in command resolution, in this process and in every
    # child process that also imports it below.
    Import-Module gh -Force

    # ---- helpers -----------------------------------------------------
    function Start-DummyProcess {
        # A real, harmless background process, standing in for a slot's
        # runner-loop.ps1 without touching anything real. Returns its
        # Process object.
        $shell = 'powershell'
        if (Get-Command pwsh -ErrorAction SilentlyContinue) { $shell = 'pwsh' }
        $p = Start-Process -FilePath $shell -ArgumentList @('-NoProfile', '-Command', $dummyCommand) `
            -WindowStyle Hidden -PassThru
        return (Register-Spawned $p)
    }

    function New-Slot {
        param([string]$PoolDir, [int]$Index, [switch]$Running)
        $slot = Join-Path $PoolDir "slot-$Index"
        New-Item -ItemType Directory -Force -Path $slot | Out-Null
        Set-Content -Path (Join-Path $slot 'config.cmd') -Value 'rem placeholder, prevents a real download'
        if ($Running) {
            $slotProc = Start-DummyProcess
            Set-Content -Path (Join-Path $slot '.pid') -Value $slotProc.Id
        }
        return $slot
    }

    function New-Pool {
        param([string]$Name, [string]$Repo, [int]$SlotCount, [int]$RunningCount = 0)
        $poolDir = Join-Path $runnersRoot $Name
        New-Item -ItemType Directory -Force -Path $poolDir | Out-Null
        if ($Repo) { Set-Content -Path (Join-Path $poolDir '.repo') -Value $Repo }
        for ($i = 1; $i -le $SlotCount; $i++) {
            New-Slot -PoolDir $poolDir -Index $i -Running:($i -le $RunningCount) | Out-Null
        }
        return $poolDir
    }

    # Whether a child's output contains an expected phrase, with every run
    # of whitespace in both collapsed to one space. Both shells word-wrap a
    # child's stderr at the host's width, and that width depends on how the
    # suite itself was launched -- a console, a pipe, or a file all differ,
    # so `powershell -File <this> > out.txt` wrapped "can't confirm it is
    # idle" mid-phrase and failed three checks that pass when run straight.
    # An expected phrase is a phrase, not a line: it should not have to
    # survive a line break, nor be kept short enough to dodge one.
    function Test-OutputContains {
        param([string]$Text, [string]$Want)
        $flatText = ($Text -replace '\s+', ' ')
        $flatWant = ($Want -replace '\s+', ' ')
        return ($flatText -like "*$flatWant*")
    }

    function Check {
        param([string]$Desc, [int]$WantStatus, [string]$WantOut, [scriptblock]$Action)
        # Local to this function only ($ErrorActionPreference is scoped,
        # not dynamic): the script-wide 'Stop' at the top of this file
        # would otherwise turn a child process's own stderr text (e.g.
        # Invoke-PoolDie's Write-PoolError) into a terminating
        # NativeCommandError the moment it's merged with 2>&1, well before
        # $out below gets a chance to see and check it.
        # Not resetting FAKE_GH_FAIL/FAKE_RUNNERS here: the caller sets up
        # this check's scenario in those env vars immediately before
        # calling Check, and clears them again afterward -- resetting them
        # on entry would wipe out the scenario before $Action ever runs.
        $ErrorActionPreference = 'Continue'
        $out = & $Action 2>&1 | Out-String
        $status = $LASTEXITCODE
        if ($null -eq $status) { $status = 0 }
        if ($status -eq $WantStatus -and (Test-OutputContains -Text $out -Want $WantOut)) {
            Write-Host "ok   $Desc"
        } else {
            Write-Host "FAIL ${Desc}: exit $status (want $WantStatus), output: $out"
            $script:fails = $script:fails + 1
        }
    }

    $hostLabel = 'H'
    $env:COMPUTERNAME_BACKUP = $env:COMPUTERNAME
    # Force a stable, predictable COMPUTERNAME for runner-name matching in
    # this test process only.
    $env:COMPUTERNAME = 'C'

    # ==================================================================
    # PoolSlot.ps1 library, called directly
    # ==================================================================
    . (Join-Path $winDir 'PoolSlot.ps1')

    if ((Get-PoolConfLine -ConfPath $confPath -Name 'worm').Repo -eq 'o/r' -and
        (Get-PoolConfLine -ConfPath $confPath -Name 'worm').Count -eq 2) {
        Write-Host 'ok   Get-PoolConfLine reads a declared pool'
    } else { Write-Host 'FAIL Get-PoolConfLine reads a declared pool'; $fails++ }

    if ($null -eq (Get-PoolConfLine -ConfPath $confPath -Name 'stray')) {
        Write-Host 'ok   Get-PoolConfLine returns null for an undeclared pool'
    } else { Write-Host 'FAIL Get-PoolConfLine returns null for an undeclared pool'; $fails++ }

    if ((Get-SlotRunnerName -HostLabel 'H' -Name 'worm' -Index 3) -eq 'H-C-worm-slot3') {
        Write-Host 'ok   Get-SlotRunnerName matches Start-RunnerPool.ps1''s format'
    } else { Write-Host 'FAIL Get-SlotRunnerName matches Start-RunnerPool.ps1''s format'; $fails++ }

    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot1","status":"online","busy":true},{"name":"H-C-worm-slot2","status":"offline","busy":false}]'
    $runners = Get-GhRunnersForRepo -Repo 'o/r'
    if ($runners.Count -eq 2) { Write-Host 'ok   Get-GhRunnersForRepo parses the fake response' }
    else { Write-Host "FAIL Get-GhRunnersForRepo parses the fake response: got $($runners.Count)"; $fails++ }

    $m = Find-RunnerByName -Runners $runners -Name 'h-c-worm-slot1'
    if ($m -and $m.busy -eq $true) { Write-Host 'ok   Find-RunnerByName matches case-insensitively' }
    else { Write-Host 'FAIL Find-RunnerByName matches case-insensitively'; $fails++ }

    $env:FAKE_GH_FAIL = '1'
    $failed = Get-GhRunnersForRepo -Repo 'o/r'
    if ($null -eq $failed) { Write-Host 'ok   Get-GhRunnersForRepo returns null when gh fails' }
    else { Write-Host 'FAIL Get-GhRunnersForRepo returns null when gh fails'; $fails++ }
    $env:FAKE_GH_FAIL = $null

    $stats = Get-RunnerMatchStats -Repo 'o/r' -RunnerNames @('H-C-worm-slot1', 'H-C-worm-slot2', 'H-C-worm-slot9')
    $env:FAKE_RUNNERS = $null
    if ($stats.Known -and $stats.Matched -eq 2 -and $stats.Busy -eq 1 -and $stats.Online -eq 1) {
        Write-Host 'ok   Get-RunnerMatchStats counts matched/online/busy'
    } else {
        Write-Host "FAIL Get-RunnerMatchStats counts matched/online/busy: $($stats | ConvertTo-Json -Compress)"
        $fails++
    }

    # ==================================================================
    # Assert-RunnersIdle, in a child process each time since it calls exit
    # ==================================================================
    $assertScript = Join-Path $tmp 'assert-idle.ps1'
    Set-Content -Path $assertScript -Value @"
Import-Module gh -Force
. '$($winDir -replace "'", "''")\PoolSlot.ps1'
`$names = if (`$env:TEST_NO_RUNNER_NAMES -eq '1') { @() } else { @('H-C-worm-slot1','H-C-worm-slot2') }
Assert-RunnersIdle -Label 'pool ''worm''' -Repo `$env:TEST_REPO -RunnerNames `$names -HasSlots:(-not [bool]`$env:TEST_NO_SLOTS) -Force:([bool]`$env:TEST_FORCE)
Write-Output 'idle-ok'
"@
    $shellExe = 'powershell'
    if (Get-Command pwsh -ErrorAction SilentlyContinue) { $shellExe = 'pwsh' }

    $env:TEST_REPO = 'o/r'; $env:TEST_FORCE = ''
    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot1","status":"online","busy":true}]'
    Check 'Assert-RunnersIdle refuses while a runner is busy' 3 '1 busy runner' { & $shellExe -NoProfile -File $assertScript }

    $env:FAKE_RUNNERS = $null
    $env:FAKE_GH_FAIL = '1'
    Check 'Assert-RunnersIdle refuses when GitHub cannot be asked' 3 'could not ask GitHub' { & $shellExe -NoProfile -File $assertScript }
    $env:FAKE_GH_FAIL = $null

    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot9","status":"online","busy":false}]'
    Check 'Assert-RunnersIdle refuses when nothing matches' 3 "can't confirm it is idle" { & $shellExe -NoProfile -File $assertScript }

    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot1","status":"online","busy":false},{"name":"H-C-worm-slot2","status":"online","busy":false}]'
    Check 'Assert-RunnersIdle passes when everything is idle' 0 'idle-ok' { & $shellExe -NoProfile -File $assertScript }

    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot1","status":"online","busy":true}]'
    $env:TEST_FORCE = '1'
    Check 'Assert-RunnersIdle -Force skips the check' 0 'idle-ok' { & $shellExe -NoProfile -File $assertScript }
    $env:TEST_FORCE = ''
    $env:FAKE_RUNNERS = $null

    # -HasSlots is what actually gates the skip, not an empty RunnerNames
    # list on its own: a pool with genuinely no slot directories is safe
    # to skip (nothing there), but a pool whose slot directories all
    # failed to parse into a runner name is NOT the same thing -- one of
    # those directories could still hold a live, possibly mid-job process
    # (see PoolSlot.ps1's comment on Assert-RunnersIdle). Both scenarios
    # leave RunnerNames empty; only -HasSlots tells them apart.
    $env:TEST_NO_SLOTS = '1'
    $env:FAKE_GH_FAIL = '1'
    Check 'Assert-RunnersIdle skips the check when the pool truly has no slots' 0 'idle-ok' { & $shellExe -NoProfile -File $assertScript }
    $env:TEST_NO_SLOTS = ''
    $env:FAKE_GH_FAIL = $null

    $env:TEST_NO_RUNNER_NAMES = '1'
    Check 'Assert-RunnersIdle refuses when a pool has slots but none parsed to a runner name' 3 "can't confirm it is idle" { & $shellExe -NoProfile -File $assertScript }
    $env:TEST_NO_RUNNER_NAMES = ''

    # ==================================================================
    # Stop-Slot
    # ==================================================================
    $poolForStopSlot = New-Pool -Name 'stopslot' -Repo 'o/r' -SlotCount 1 -RunningCount 0
    $slotNoPid = Join-Path $poolForStopSlot 'slot-1'
    if (Stop-Slot -SlotDir $slotNoPid -SlotLabel 'stopslot slot-1') {
        Write-Host 'ok   Stop-Slot with no .pid file reports stopped'
    } else { Write-Host 'FAIL Stop-Slot with no .pid file reports stopped'; $fails++ }

    $deadPidSlot = Join-Path $poolForStopSlot 'slot-2'
    New-Item -ItemType Directory -Force -Path $deadPidSlot | Out-Null
    Set-Content -Path (Join-Path $deadPidSlot '.pid') -Value 999999
    if ((Stop-Slot -SlotDir $deadPidSlot -SlotLabel 'stopslot slot-2') -and -not (Test-Path (Join-Path $deadPidSlot '.pid'))) {
        Write-Host 'ok   Stop-Slot with a dead pid cleans up the .pid file'
    } else { Write-Host 'FAIL Stop-Slot with a dead pid cleans up the .pid file'; $fails++ }

    $runningSlot = Join-Path $poolForStopSlot 'slot-3'
    New-Item -ItemType Directory -Force -Path $runningSlot | Out-Null
    $runningProc = Start-DummyProcess
    Set-Content -Path (Join-Path $runningSlot '.pid') -Value $runningProc.Id
    if (-not (Stop-Slot -SlotDir $runningSlot -SlotLabel 'stopslot slot-3' -TimeoutSeconds 1)) {
        Write-Host 'ok   Stop-Slot without -Force leaves a running process running'
    } else { Write-Host 'FAIL Stop-Slot without -Force leaves a running process running'; $fails++ }
    if (Stop-Slot -SlotDir $runningSlot -SlotLabel 'stopslot slot-3' -Force -TimeoutSeconds 1) {
        Write-Host 'ok   Stop-Slot -Force kills a still-running process'
    } else { Write-Host 'FAIL Stop-Slot -Force kills a still-running process'; $fails++ }
    # A kill doesn't guarantee the process is gone the instant it returns --
    # give it a moment before concluding it's still alive. Asked of the
    # held handle, not Get-Process -Id: that PID may already be someone
    # else's.
    if ($runningProc.WaitForExit(10000)) {
        Write-Host 'ok   Stop-Slot -Force actually terminated the process'
    } else { Write-Host 'FAIL Stop-Slot -Force actually terminated the process'; $fails++ }

    # A slot's runner-loop.ps1 has children of its own (run.cmd, and the
    # Runner.Listener under it), and Windows doesn't take children down
    # with their parent: Stop-Slot -Force has to kill the whole tree, or a
    # listener outlives its slot and keeps taking jobs.
    $childPidFile = Join-Path $tmp 'child.pid'
    $parentScript = Join-Path $tmp 'parent.ps1'
    Set-Content -Path $parentScript -Value @"
`$child = Start-Process -FilePath '$shellExe' -ArgumentList @('-NoProfile', '-Command', '$dummyCommand') -WindowStyle Hidden -PassThru
Set-Content -Path '$($childPidFile -replace "'", "''")' -Value `$child.Id
$dummyCommand
"@
    $parent = Start-Process -FilePath $shellExe -ArgumentList @('-NoProfile', '-File', $parentScript) -WindowStyle Hidden -PassThru
    [void](Register-Spawned $parent)
    # Waits for the file to hold a PID, not just to exist, and holds the
    # child's handle open from here on -- same reasons as any slot's .pid
    # file, so the same function does it.
    $childProc = $null
    for ($i = 0; $i -lt 100 -and -not $childProc; $i++) {
        Start-Sleep -Milliseconds 100
        $childProc = Register-SlotPidFile $childPidFile
    }
    if ($childProc) {
        $treeSlot = Join-Path $poolForStopSlot 'slot-4'
        New-Item -ItemType Directory -Force -Path $treeSlot | Out-Null
        Set-Content -Path (Join-Path $treeSlot '.pid') -Value $parent.Id
        # A code the caller hasn't looked at yet: taskkill must neither
        # replace it with its own nor wipe it.
        $global:LASTEXITCODE = 7
        [void](Stop-Slot -SlotDir $treeSlot -SlotLabel 'stopslot slot-4' -Force -TimeoutSeconds 1)
        $afterStopSlot = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($childProc.WaitForExit(10000)) {
            Write-Host 'ok   Stop-Slot -Force kills the slot process''s children too'
        } else { Write-Host 'FAIL Stop-Slot -Force kills the slot process''s children too'; $fails++ }
        if ($afterStopSlot -ne 7) {
            Write-Host "FAIL Stop-Slot leaves its caller's `$LASTEXITCODE as it was: $afterStopSlot"; $fails++
        } else { Write-Host 'ok   Stop-Slot leaves its caller''s $LASTEXITCODE as it was' }
    } else { Write-Host 'FAIL Stop-Slot tree test: the parent never started its child'; $fails++ }

    # ==================================================================
    # windows-pools.ps1 end to end
    # ==================================================================
    $wp = Join-Path $tmp 'windows-pools.ps1'

    # Start-RunnerPool.ps1 (unlike Restart-RunnerSlot.ps1) refuses outright
    # if pat.secret doesn't exist at all, before launching any slot -- so
    # 'start' needs one present to get as far as actually spawning a
    # process. Empty, not absent: runner-loop.ps1 fails on its own
    # PAT-is-empty check (see runner-loop.ps1's own header) before it ever
    # reaches Invoke-RunnerApi, so this still never touches the network,
    # the same safety the "no pat.secret" trick gives the restart-runner
    # tests below.
    New-Item -ItemType File -Force -Path (Join-Path $tmp 'pat.secret') | Out-Null

    # Every child invocation below runs through this wrapper rather than
    # `-File $wp` directly, so the fake gh module is imported (and so wins
    # over any real gh.exe on this machine's PATH -- see the Import-Module
    # gh -Force comment above) before windows-pools.ps1 itself runs.
    $wpWrapper = Join-Path $tmp 'wp-wrapper.ps1'
    Set-Content -Path $wpWrapper -Value @"
# Deliberately no [Parameter(ValueFromRemainingArguments)] here -- once
# script args are bound into a user-declared [string[]] parameter and
# re-splatted, PowerShell treats every element as a plain positional
# value, so a forwarded '-HostLabel' no longer binds by name and
# windows-pools.ps1 rejects it as a stray positional argument. The
# automatic `$args variable is specially recognised by splatting and keeps
# that named-argument behaviour, so use it instead.
Import-Module gh -Force
& '$($wp -replace "'", "''")' @args
exit `$LASTEXITCODE
"@

    function Invoke-Wp {
        param([string[]]$WpArgs)
        # $ErrorActionPreference reason: see Check's comment above.
        $ErrorActionPreference = 'Continue'
        Push-Location $tmp
        try {
            # The captured text is discarded on purpose (assigned to
            # $null): left as an unassigned pipeline expression, it would
            # become part of this function's own output alongside
            # $LASTEXITCODE below, turning "$status = Invoke-Wp ..." into
            # a two-element array instead of a plain exit code.
            $null = & $shellExe -NoProfile -File $wpWrapper @WpArgs 2>&1 | Out-String
            return $LASTEXITCODE
        } finally { Pop-Location }
    }
    function Check-Wp {
        param([string]$Desc, [int]$WantStatus, [string]$WantOut, [string[]]$WpArgs)
        # See Check's comment above -- same reasons, on both counts.
        $ErrorActionPreference = 'Continue'
        $out = & $shellExe -NoProfile -File $wpWrapper @WpArgs 2>&1 | Out-String
        $status = $LASTEXITCODE
        if ($status -eq $WantStatus -and (Test-OutputContains -Text $out -Want $WantOut)) { Write-Host "ok   $Desc" }
        else { Write-Host "FAIL ${Desc}: exit $status (want $WantStatus), output: $out"; $script:fails = $script:fails + 1 }
    }

    # Rebuild pool dirs relative to $tmp's own windows\runners (Invoke-Wp
    # resolves $PSScriptRoot from $wp's own location).
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $runnersRoot
    New-Item -ItemType Directory -Force -Path $runnersRoot | Out-Null
    New-Pool -Name 'worm' -Repo 'o/r' -SlotCount 2 -RunningCount 2 | Out-Null
    New-Pool -Name 'idle' -Repo 'o/idle' -SlotCount 0 | Out-Null
    New-Pool -Name 'stray' -Repo 'o/stray' -SlotCount 1 -RunningCount 1 | Out-Null

    # -HostLabel H on every call below: windows-pools.ps1 defaults
    # -HostLabel to $env:COMPUTERNAME (forced to 'C' above), but the fake
    # GitHub runner names in FAKE_RUNNERS are all built as "H-C-worm-slotN"
    # to match Get-SlotRunnerName's format check above -- pass it
    # explicitly so the computed runner names actually match them.
    Check-Wp 'start refuses an undeclared pool' 1 "no pool named 'stray'" @('start', 'stray', '-HostLabel', 'H')
    Check-Wp 'restart refuses an undeclared pool' 1 "no pool named 'stray'" @('restart', 'stray', '-HostLabel', 'H')

    # 'start' actually reading repo/count from windows-pools.conf and
    # launching a slot -- not just its undeclared-pool refusal above.
    # 'idle' declares count 1 in $confPath ("idle   o/idle 1"), and its
    # slot-1 is pre-seeded with a placeholder config.cmd so Install-Runner
    # no-ops (no real download); pat.secret exists but is empty (see
    # above), so the launched runner-loop.ps1 fails immediately on its own
    # PAT-is-empty check, after the process (and its .pid file) already
    # exist -- which is all this checks.
    New-Slot -PoolDir (Join-Path $runnersRoot 'idle') -Index 1 | Out-Null
    # A .env already there: Start-Slot should replace a stale toolcache
    # line and keep anything else.
    $idleEnvFile = Join-Path $runnersRoot 'idle\slot-1\.env'
    Set-Content -Path $idleEnvFile -Value @('KEEP_ME=1', 'RUNNER_TOOL_CACHE=C:\stale')
    Check-Wp 'start reads repo/count from windows-pools.conf and launches a slot' 0 '' @('start', 'idle', '-HostLabel', 'H')
    $wantToolCache = Join-Path $tmp 'windows\toolcache'
    $envGot = @(Get-Content $idleEnvFile)
    if (($envGot -contains "RUNNER_TOOL_CACHE=$wantToolCache") -and ($envGot -contains "AGENT_TOOLSDIRECTORY=$wantToolCache") `
            -and ($envGot -contains 'KEEP_ME=1') -and -not ($envGot -contains 'RUNNER_TOOL_CACHE=C:\stale')) {
        Write-Host 'ok   start writes the toolcache into the slot''s runner .env'
    } else { Write-Host "FAIL start writes the toolcache into the slot's runner .env: $($envGot -join ' | ')"; $fails++ }
    $idlePidFile = Join-Path $runnersRoot 'idle\slot-1\.pid'
    if (Test-Path $idlePidFile) {
        [void](Register-SlotPidFile $idlePidFile)
        Write-Host 'ok   start launched slot-1 and recorded its pid'
    } else { Write-Host 'FAIL start launched slot-1 and recorded its pid'; $fails++ }
    $idleRepoFile = Join-Path $runnersRoot 'idle\.repo'
    if ((Test-Path $idleRepoFile) -and ((Get-Content $idleRepoFile).Trim() -eq 'o/idle')) {
        Write-Host 'ok   start recorded the repo from windows-pools.conf'
    } else { Write-Host 'FAIL start recorded the repo from windows-pools.conf'; $fails++ }

    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot1","status":"online","busy":true},{"name":"H-C-worm-slot2","status":"online","busy":false}]'
    Check-Wp 'stop refuses while a runner is busy' 3 '1 busy runner' @('stop', 'worm', '-HostLabel', 'H')
    Check-Wp 'restart refuses while a runner is busy' 3 '1 busy runner' @('restart', 'worm', '-HostLabel', 'H')
    $env:FAKE_RUNNERS = $null

    $env:FAKE_GH_FAIL = '1'
    Check-Wp 'stop refuses when GitHub cannot be asked' 3 'could not ask GitHub' @('stop', 'worm', '-HostLabel', 'H')
    $env:FAKE_GH_FAIL = $null

    # A pool with a slot on disk (so Assert-RunnersIdle has something to
    # check) but no .repo file and no windows-pools.conf line -- the one
    # way "which repo does this serve" can actually be unknown.
    New-Pool -Name 'stray2' -SlotCount 1 -RunningCount 1 | Out-Null
    Check-Wp 'stop rejects a pool with no repo recorded and no declared repo' 3 "can't tell which repo" @('stop', 'stray2', '-HostLabel', 'H')

    # A pool whose only slot directory doesn't parse into a runner name at
    # all (see windows-pools.ps1's own Get-PoolRunnerNames and PoolSlot.ps1's
    # Assert-RunnersIdle -HasSlots comment): this used to leave RunnerNames
    # empty and skip the busy check entirely -- silently force-stopping
    # whatever process actually lived under that directory, busy or not.
    New-Pool -Name 'onlybogus' -Repo 'o/onlybogus' -SlotCount 0 | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $runnersRoot 'onlybogus\slot-bogus') | Out-Null
    Check-Wp 'stop refuses a pool whose only slot directory has no parseable index' 3 "can't confirm it is idle" @('stop', 'onlybogus', '-HostLabel', 'H')

    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot1","status":"online","busy":false},{"name":"H-C-worm-slot2","status":"online","busy":false}]'
    Check-Wp 'stop an idle pool succeeds' 0 '' @('stop', 'worm', '-HostLabel', 'H')
    $env:FAKE_RUNNERS = $null

    # worm is now stopped; re-seed it running for the -Force test.
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $runnersRoot 'worm')
    New-Pool -Name 'worm' -Repo 'o/r' -SlotCount 2 -RunningCount 2 | Out-Null
    $env:FAKE_GH_FAIL = '1'
    Check-Wp 'stop -Force skips the busy check' 0 '' @('stop', 'worm', '-Force', '-HostLabel', 'H')
    $env:FAKE_GH_FAIL = $null

    # ---- restart-runner ----
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $runnersRoot 'worm')
    New-Pool -Name 'worm' -Repo 'o/r' -SlotCount 2 -RunningCount 2 | Out-Null
    # A malformed slot directory alongside the real ones, for every test
    # below: Restart-RunnerSlot.ps1's pool-wide fallback match (used
    # whenever the target runner itself isn't directly registered) used to
    # call Get-SlotRunnerName -Index on this without checking whether
    # Get-SlotIndex parsed one first, which threw and aborted
    # restart-runner instead of just skipping it.
    New-Item -ItemType Directory -Force -Path (Join-Path $runnersRoot 'worm\slot-bogus') | Out-Null

    Check-Wp 'restart-runner refuses a slot that does not exist' 1 'no runner slot found' @('restart-runner', 'nosuch-runner', '-HostLabel', 'H')

    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot1","status":"online","busy":true}]'
    Check-Wp 'restart-runner refuses a busy runner' 3 'running a job' @('restart-runner', 'H-C-worm-slot1', '-HostLabel', 'H')
    $env:FAKE_RUNNERS = $null

    $env:FAKE_GH_FAIL = '1'
    Check-Wp 'restart-runner refuses when GitHub cannot be asked' 3 'could not ask GitHub' @('restart-runner', 'H-C-worm-slot1', '-HostLabel', 'H')
    $env:FAKE_GH_FAIL = $null

    # slot2's runner isn't registered, but slot1's is -- pool match succeeds
    # (via Restart-RunnerSlot.ps1's pool-wide fallback loop, which also
    # has to step over slot-bogus above without throwing) so restart-runner
    # proceeds, and ends up actually restarting slot2: config.cmd is
    # pre-seeded so Install-Runner.ps1 no-ops, and pat.secret is empty (see
    # above) so runner-loop.ps1 fails immediately on its own PAT-is-empty
    # check without touching the network.
    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot1","status":"online","busy":false}]'
    $status = Invoke-Wp -WpArgs @('restart-runner', 'H-C-worm-slot2', '-HostLabel', 'H')
    if ($status -eq 0) { Write-Host 'ok   restart-runner proceeds when the pool has at least one match' }
    else { Write-Host "FAIL restart-runner proceeds when the pool has at least one match: exit $status"; $fails++ }
    $env:FAKE_RUNNERS = $null
    Start-Sleep -Milliseconds 500
    $newPidFile = Join-Path $runnersRoot 'worm\slot-2\.pid'
    if (Test-Path $newPidFile) {
        [void](Register-SlotPidFile $newPidFile)
        Write-Host 'ok   restart-runner actually re-launched the slot'
    } else { Write-Host 'FAIL restart-runner actually re-launched the slot'; $fails++ }

    # ---- list -Json ----
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $runnersRoot
    New-Item -ItemType Directory -Force -Path $runnersRoot | Out-Null
    New-Pool -Name 'worm' -Repo 'o/r' -SlotCount 2 -RunningCount 1 | Out-Null
    New-Pool -Name 'idle' -Repo 'o/idle' -SlotCount 0 | Out-Null
    New-Pool -Name 'stray' -Repo 'o/stray' -SlotCount 1 -RunningCount 1 | Out-Null

    $env:FAKE_RUNNERS = '[{"name":"H-C-worm-slot1","status":"online","busy":true}]'
    $jsonOut = & $shellExe -NoProfile -File $wpWrapper @('list', '-Json', 'worm', '-HostLabel', 'H') 2>&1 | Out-String
    $env:FAKE_RUNNERS = $null
    try {
        $parsed = $jsonOut | ConvertFrom-Json
        $pool = $parsed[0]
        if ($pool.name -eq 'worm' -and $pool.project -eq 'worm' -and $pool.repo -eq 'o/r' -and $pool.managed -eq $true `
                -and $pool.desired -eq 2 -and $null -eq $pool.label -and $pool.os -eq 'windows' `
                -and $pool.containers.total -eq 2 -and $pool.containers.running -eq 1 `
                -and $pool.runners.online -eq 1 -and $pool.runners.busy -eq 1 -and $pool.members.Count -eq 2) {
            Write-Host 'ok   list -Json worm has the expected shape'
        } else {
            Write-Host "FAIL list -Json worm has the expected shape: $jsonOut"
            $fails++
        }
        $m1 = $pool.members | Where-Object { $_.container -eq 'H-C-worm-slot1' }
        if ($m1.runner.busy -eq $true -and $m1.state -eq 'running') {
            Write-Host 'ok   list -Json member carries its matched runner and state'
        } else { Write-Host "FAIL list -Json member carries its matched runner and state: $($m1 | ConvertTo-Json -Compress)"; $fails++ }
    } catch {
        Write-Host "FAIL list -Json worm produced invalid JSON: $_"
        $fails++
    }

    $jsonAll = & $shellExe -NoProfile -File $wpWrapper @('list', '-Json') 2>&1 | Out-String
    try {
        $parsedAll = $jsonAll | ConvertFrom-Json
        $names = $parsedAll | ForEach-Object { $_.name }
        $strayEntry = $parsedAll | Where-Object { $_.name -eq 'stray' }
        if (($names -contains 'worm') -and ($names -contains 'idle') -and ($names -contains 'stray') -and $strayEntry.managed -eq $false) {
            Write-Host 'ok   list -Json with no names includes declared and undeclared pools'
        } else { Write-Host "FAIL list -Json with no names includes declared and undeclared pools: $jsonAll"; $fails++ }
    } catch {
        Write-Host "FAIL list -Json with no names produced invalid JSON: $_"
        $fails++
    }

    $jsonMissing = & $shellExe -NoProfile -File $wpWrapper @('list', '-Json', 'nosuch') 2>&1 | Out-String
    if ($jsonMissing.Trim() -eq '[]') { Write-Host 'ok   list -Json drops a name nobody knows' }
    else { Write-Host "FAIL list -Json drops a name nobody knows: $jsonMissing"; $fails++ }

    $env:GH_FAIL_FOR_IDLE = $null
    $env:FAKE_GH_FAIL = '1'
    $jsonGhFail = & $shellExe -NoProfile -File $wpWrapper @('list', '-Json', 'worm') 2>&1 | Out-String
    $env:FAKE_GH_FAIL = $null
    try {
        $parsedFail = ($jsonGhFail | ConvertFrom-Json)[0]
        if ($null -eq $parsedFail.runners -and $null -eq $parsedFail.members[0].runner) {
            Write-Host 'ok   list -Json reports runners null when GitHub cannot be asked'
        } else { Write-Host "FAIL list -Json reports runners null when GitHub cannot be asked: $jsonGhFail"; $fails++ }
    } catch {
        Write-Host "FAIL list -Json (gh failing) produced invalid JSON: $_"
        $fails++
    }

    # A pool with slots but no .repo and no conf line (like 'stray2' in the
    # stop tests above), plus a malformed "slot-*" directory whose name
    # doesn't parse as slot-<digits> -- Get-SlotRunnerName's -Index is
    # Mandatory/[int], so Get-PoolStatusObject skipping a $null index (see
    # PoolSlot.ps1) is what keeps this from throwing and aborting the
    # whole listing.
    New-Pool -Name 'norepo' -SlotCount 1 -RunningCount 1 | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $runnersRoot 'norepo\slot-bogus') | Out-Null
    $jsonNoRepo = & $shellExe -NoProfile -File $wpWrapper @('list', '-Json', 'norepo') 2>&1 | Out-String
    try {
        $parsedNoRepo = ($jsonNoRepo | ConvertFrom-Json)[0]
        if ($parsedNoRepo.name -eq 'norepo' -and $null -eq $parsedNoRepo.repo -and $parsedNoRepo.managed -eq $false `
                -and $parsedNoRepo.containers.total -eq 1 -and $parsedNoRepo.members.Count -eq 1) {
            Write-Host 'ok   list -Json handles a pool with no repo and a malformed slot directory'
        } else { Write-Host "FAIL list -Json handles a pool with no repo and a malformed slot directory: $jsonNoRepo"; $fails++ }
    } catch {
        Write-Host "FAIL list -Json (no repo, malformed slot dir) produced invalid JSON: $_"
        $fails++
    }

    # ---- Set-PoolConfCount, called directly ----
    $unitConf = Join-Path $tmp 'unit-pools.conf'
    Set-Content -Path $unitConf -Value @('# keep me', 'a   o/a   9', 'b   o/b')
    $oldA = Set-PoolConfCount -ConfPath $unitConf -Name 'a' -Count 10
    $oldB = Set-PoolConfCount -ConfPath $unitConf -Name 'b' -Count 3
    $same = Set-PoolConfCount -ConfPath $unitConf -Name 'b' -Count 3
    $got = @(Get-Content $unitConf)
    if ($oldA -eq 9 -and $oldB -eq 2 -and $null -eq $same -and $got.Count -eq 3 -and $got[0] -eq '# keep me' `
            -and $got[1] -eq 'a   o/a   10' -and $got[2] -eq 'b   o/b 3') {
        Write-Host 'ok   Set-PoolConfCount rewrites one count, adds a missing one, and leaves the rest alone'
    } else {
        Write-Host "FAIL Set-PoolConfCount rewrites one count, adds a missing one, and leaves the rest alone: $oldA/$oldB/$same, $($got -join ' | ')"
        $fails++
    }

    # ---- scale ----
    # A pool of its own, appended here rather than declared at the top:
    # scale rewrites its pool's count in windows-pools.conf, and the checks
    # above read worm's and idle's.
    Add-Content -Path $confPath -Value 'sc     o/sc   2'
    $scDir = Join-Path $runnersRoot 'sc'

    Check-Wp 'scale refuses an undeclared pool' 1 "no pool named 'stray'" @('scale', 'stray', '2', '-HostLabel', 'H')
    # Just "non-negative", rather than the whole sentence: short enough to
    # read as one assertion. Where it sits relative to a line break no
    # longer matters -- Test-OutputContains flattens both sides.
    Check-Wp 'scale rejects a non-numeric count' 1 'non-negative' @('scale', 'sc', 'abc', '-HostLabel', 'H')
    Check-Wp 'scale rejects a missing count' 1 'usage' @('scale', 'sc', '-HostLabel', 'H')

    New-Pool -Name 'sc' -Repo 'o/sc' -SlotCount 3 -RunningCount 3 | Out-Null
    $env:FAKE_RUNNERS = '[{"name":"H-C-sc-slot1","status":"online","busy":false},{"name":"H-C-sc-slot3","status":"online","busy":true}]'
    Check-Wp 'scale down refuses when a slot it would stop is busy' 3 '1 busy runner' @('scale', 'sc', '1', '-HostLabel', 'H')
    if ((Get-PoolConfLine -ConfPath $confPath -Name 'sc').Count -eq 2 -and (Test-SlotRunning -SlotDir (Join-Path $scDir 'slot-3'))) {
        Write-Host 'ok   a refused scale leaves the slot running and windows-pools.conf alone'
    } else { Write-Host 'FAIL a refused scale leaves the slot running and windows-pools.conf alone'; $fails++ }

    # Only slot-1 is busy, and scaling to 1 keeps slot-1.
    $env:FAKE_RUNNERS = '[{"name":"H-C-sc-slot1","status":"online","busy":true},{"name":"H-C-sc-slot2","status":"online","busy":false},{"name":"H-C-sc-slot3","status":"online","busy":false}]'
    Check-Wp 'scale down only checks the slots it stops' 0 'windows-pools.conf now declares sc at 1 (was 2)' @('scale', 'sc', '1', '-HostLabel', 'H')
    $env:FAKE_RUNNERS = $null
    if (-not (Test-Path (Join-Path $scDir 'slot-2')) -and -not (Test-Path (Join-Path $scDir 'slot-3')) `
            -and (Test-SlotRunning -SlotDir (Join-Path $scDir 'slot-1'))) {
        Write-Host 'ok   scale down removes the highest slots and keeps the rest running'
    } else { Write-Host 'FAIL scale down removes the highest slots and keeps the rest running'; $fails++ }
    if ((Get-PoolConfLine -ConfPath $confPath -Name 'sc').Count -eq 1) {
        Write-Host 'ok   scale writes the new count to windows-pools.conf'
    } else { Write-Host 'FAIL scale writes the new count to windows-pools.conf'; $fails++ }

    New-Slot -PoolDir $scDir -Index 2 -Running | Out-Null
    $env:FAKE_GH_FAIL = '1'
    Check-Wp 'scale down refuses when GitHub cannot be asked' 3 'could not ask GitHub' @('scale', 'sc', '1', '-HostLabel', 'H')
    Check-Wp 'scale down -Force skips the busy check' 0 '' @('scale', 'sc', '1', '-Force', '-HostLabel', 'H')
    if (-not (Test-Path (Join-Path $scDir 'slot-2'))) {
        Write-Host 'ok   scale down -Force stops and removes the slot'
    } else { Write-Host 'FAIL scale down -Force stops and removes the slot'; $fails++ }

    # Growing never asks GitHub (still failing here): nothing running is
    # touched. The new slots are pre-seeded with a placeholder config.cmd so
    # Install-Runner.ps1 no-ops, and pat.secret is empty, so each
    # runner-loop.ps1 they launch exits before any network call.
    New-Slot -PoolDir $scDir -Index 2 | Out-Null
    New-Slot -PoolDir $scDir -Index 3 | Out-Null
    Check-Wp 'scale up never refuses' 0 'windows-pools.conf now declares sc at 3 (was 1)' @('scale', 'sc', '3', '-HostLabel', 'H')
    $env:FAKE_GH_FAIL = $null
    $grown = 0
    foreach ($i in 2, 3) {
        $grownPid = Join-Path $scDir "slot-$i\.pid"
        if (Test-Path $grownPid) { [void](Register-SlotPidFile $grownPid); $grown++ }
    }
    if ($grown -eq 2) { Write-Host 'ok   scale up starts the new slots' }
    else { Write-Host "FAIL scale up starts the new slots: $grown of 2 started"; $fails++ }

    $confBefore = Get-Content -Raw $confPath
    $status = Invoke-Wp -WpArgs @('scale', 'sc', '3', '-HostLabel', 'H')
    if ($status -eq 0 -and (Get-Content -Raw $confPath) -eq $confBefore) {
        Write-Host 'ok   scale to the size windows-pools.conf already declares leaves it alone'
    } else { Write-Host "FAIL scale to the size windows-pools.conf already declares leaves it alone: exit $status"; $fails++ }

    # Down to 0: every slot is stopped and removed, and nothing is started
    # again -- the one path that skips Start-RunnerPool.ps1 altogether.
    New-Slot -PoolDir $scDir -Index 1 -Running | Out-Null
    $env:FAKE_RUNNERS = '[{"name":"H-C-sc-slot1","status":"online","busy":false}]'
    Check-Wp 'scale to 0 stops every slot' 0 'windows-pools.conf now declares sc at 0 (was 3)' @('scale', 'sc', '0', '-HostLabel', 'H')
    $env:FAKE_RUNNERS = $null
    if (@(Get-PoolSlotDirs -PoolDir $scDir).Count -eq 0 -and (Get-PoolConfLine -ConfPath $confPath -Name 'sc').Count -eq 0) {
        Write-Host 'ok   scale to 0 removes every slot and declares 0'
    } else { Write-Host "FAIL scale to 0 removes every slot and declares 0: $(@(Get-PoolSlotDirs -PoolDir $scDir).Count) slot(s) left"; $fails++ }

    # And back up from no slots at all, with GitHub failing: nothing to
    # remove, so nothing to ask. slot-1's placeholder config.cmd is only
    # there so Install-Runner.ps1 doesn't download a real runner.
    New-Slot -PoolDir $scDir -Index 1 | Out-Null
    $env:FAKE_GH_FAIL = '1'
    Check-Wp 'scale up from 0 never refuses' 0 'windows-pools.conf now declares sc at 1 (was 0)' @('scale', 'sc', '1', '-HostLabel', 'H')
    $env:FAKE_GH_FAIL = $null
    $zeroGrownPid = Join-Path $scDir 'slot-1\.pid'
    if (Test-Path $zeroGrownPid) {
        [void](Register-SlotPidFile $zeroGrownPid)
        Write-Host 'ok   scale up from 0 starts the slot'
    } else { Write-Host 'FAIL scale up from 0 starts the slot'; $fails++ }

    # ---- declare ----
    $confBeforeDeclare = Get-Content -Raw $confPath
    Check-Wp 'declare refuses a pool that is already declared' 1 'already declared' @('declare', 'worm', 'o/other', '-HostLabel', 'H')
    Check-Wp 'declare refuses a bad name' 1 'lowercase' @('declare', 'Bad', 'o/bad', '-HostLabel', 'H')
    Check-Wp 'declare refuses a bad repo' 1 'owner/repo' @('declare', 'fresh', 'nope', '-HostLabel', 'H')
    Check-Wp 'declare refuses a bad count' 1 'non-negative' @('declare', 'fresh', 'o/fresh', 'two', '-HostLabel', 'H')
    if ((Get-Content -Raw $confPath) -eq $confBeforeDeclare) {
        Write-Host 'ok   a refused declare leaves windows-pools.conf alone'
    } else { Write-Host 'FAIL a refused declare leaves windows-pools.conf alone'; $fails++ }

    Check-Wp 'declare adds a line' 0 'now declares fresh (o/fresh) at 1' @('declare', 'fresh', 'o/fresh', '-HostLabel', 'H')
    $freshLine = Get-PoolConfLine -ConfPath $confPath -Name 'fresh'
    if ($freshLine -and $freshLine.Repo -eq 'o/fresh' -and $freshLine.Count -eq 1 `
            -and (Get-PoolConfLine -ConfPath $confPath -Name 'worm')) {
        Write-Host 'ok   declare adds a line for the pool and keeps the others'
    } else { Write-Host 'FAIL declare adds a line for the pool and keeps the others'; $fails++ }

    # slot-1's placeholder config.cmd is only there so Install-Runner.ps1
    # doesn't download a real runner.
    New-Slot -PoolDir (Join-Path $runnersRoot 'fresh') -Index 1 | Out-Null
    Check-Wp 'a declared pool can be started' 0 '' @('start', 'fresh', '-HostLabel', 'H')
    $freshPid = Join-Path $runnersRoot 'fresh\slot-1\.pid'
    if (Test-Path $freshPid) {
        [void](Register-SlotPidFile $freshPid)
        Write-Host 'ok   start brings a declared pool up'
    } else { Write-Host 'FAIL start brings a declared pool up'; $fails++ }

    # ---- autoscale ----
    # "as" and "as2" both serve o/as, so a queued job belongs to "as", the
    # first declared.
    Add-Content -Path $confPath -Value @('as     o/as   1', 'as2    o/as   1')
    $asConf = Join-Path $tmp 'windows-autoscale.conf'
    $asState = Join-Path $tmp '.windows-autoscale-state'
    $asDir = Join-Path $runnersRoot 'as'
    $winJobs = '[{"status":"queued","labels":["self-hosted","Windows"]},{"status":"queued","labels":["self-hosted","windows","x64"]}]'
    $asIdle = '[{"name":"H-C-as-slot1","status":"online","busy":false},{"name":"H-C-as-slot2","status":"online","busy":false},{"name":"H-C-as-slot3","status":"online","busy":false}]'

    Check-Wp 'autoscale refuses without windows-autoscale.conf' 1 'windows-autoscale.conf' @('autoscale', '-Once', '-HostLabel', 'H')
    Set-Content -Path $asConf -Value @('# name min max idle', 'as 0 3 5', 'as2 0 2', 'ghost 0 1', 'fresh 2 1')

    New-Pool -Name 'as' -Repo 'o/as' -SlotCount 1 -RunningCount 1 | Out-Null
    New-Slot -PoolDir $asDir -Index 2 | Out-Null
    New-Slot -PoolDir $asDir -Index 3 | Out-Null
    $env:FAKE_RUNNERS = '[{"name":"H-C-as-slot1","status":"online","busy":true}]'
    $env:FAKE_JOBS = $winJobs
    Check-Wp 'autoscale -DryRun says it would grow to busy + queued' 0 'as: 1 running, 1 busy, 2 queued -> 3' @('autoscale', '-Once', '-DryRun', '-HostLabel', 'H')
    if (-not (Test-Path (Join-Path $asDir 'slot-2\.pid')) -and -not (Test-Path $asState)) {
        Write-Host 'ok   autoscale -DryRun starts nothing and writes no state'
    } else { Write-Host 'FAIL autoscale -DryRun starts nothing and writes no state'; $fails++ }
    Check-Wp 'a job counts against only the first pool for its repo' 0 'as2: 0 running, 0 busy, 0 queued -> 0' @('autoscale', '-Once', '-DryRun', '-HostLabel', 'H')
    Check-Wp 'autoscale skips a pool windows-pools.conf does not declare' 0 'ghost:' @('autoscale', '-Once', '-DryRun', '-HostLabel', 'H')
    Check-Wp 'autoscale skips a line with min > max' 0 'fresh:' @('autoscale', '-Once', '-DryRun', '-HostLabel', 'H')
    $env:FAKE_JOBS = '[{"status":"queued","labels":["self-hosted","linux"]},{"status":"queued","labels":["windows","otherhost"]},{"status":"in_progress","labels":["self-hosted","windows"]}]'
    Check-Wp 'a job for linux, another host, or already running counts against nothing' 0 'as: 1 running, 1 busy, 0 queued -> 1 (steady)' @('autoscale', '-Once', '-DryRun', '-HostLabel', 'H')
    $env:FAKE_JOBS = $winJobs
    Check-Wp 'autoscale grows a pool' 0 'as: 1 running, 1 busy, 2 queued -> 3' @('autoscale', '-Once', '-HostLabel', 'H')
    $grownAs = 0
    foreach ($i in 2, 3) {
        $p = Join-Path $asDir "slot-$i\.pid"
        if (Test-Path $p) { [void](Register-SlotPidFile $p); $grownAs++ }
    }
    if ($grownAs -eq 2) { Write-Host 'ok   autoscale starts the new slots' }
    else { Write-Host "FAIL autoscale starts the new slots: $grownAs of 2 started"; $fails++ }
    $env:FAKE_JOBS = $null

    # The started slots' runner-loop.ps1 exits at once (empty PAT), so stand
    # dummy processes in for them before checking what idle does.
    New-Slot -PoolDir $asDir -Index 2 -Running | Out-Null
    New-Slot -PoolDir $asDir -Index 3 -Running | Out-Null
    $env:FAKE_RUNNERS = $asIdle
    Check-Wp 'an idle pool waits out its idle minutes' 0 'as: 3 running, 0 busy, 0 queued -> 3 (idle, down to 0 in' @('autoscale', '-Once', '-HostLabel', 'H')
    if ((Test-Path $asState) -and (@(Get-Content $asState) -match '^as \d+$')) {
        Write-Host 'ok   ... remembered between passes'
    } else { Write-Host 'FAIL ... remembered between passes'; $fails++ }

    # The exact line, not just its shape: a refused shrink or an outage that
    # reset the clock to now would still match '^as \d+$'.
    $idleSince = "as $([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 301)"
    Set-Content -Path $asState -Value $idleSince
    $env:FAKE_RUNNERS = '[]'
    Check-Wp 'autoscale does not shrink when the busy check cannot confirm idle' 0 'not shrinking' @('autoscale', '-Once', '-HostLabel', 'H')
    if (@(Get-PoolSlotDirs -PoolDir $asDir).Count -eq 3 -and (@(Get-Content $asState) -contains $idleSince)) {
        Write-Host 'ok   ... leaving the slots and the idle clock alone'
    } else { Write-Host 'FAIL ... leaving the slots and the idle clock alone'; $fails++ }
    $env:FAKE_GH_FAIL = '1'
    Check-Wp 'autoscale leaves pools alone when GitHub cannot be asked' 0 'could not ask' @('autoscale', '-Once', '-HostLabel', 'H')
    $env:FAKE_GH_FAIL = $null
    if (@(Get-PoolSlotDirs -PoolDir $asDir).Count -eq 3 -and (@(Get-Content $asState) -contains $idleSince)) {
        Write-Host 'ok   ... keeping its idle clock'
    } else { Write-Host 'FAIL ... keeping its idle clock'; $fails++ }

    $env:FAKE_RUNNERS = $asIdle
    Check-Wp 'autoscale shrinks a pool idle past its idle minutes' 0 'as: 3 running, 0 busy, 0 queued -> 0 (idle 5m)' @('autoscale', '-Once', '-HostLabel', 'H')
    $env:FAKE_RUNNERS = $null
    if (@(Get-PoolSlotDirs -PoolDir $asDir).Count -eq 0 -and -not (@(Get-Content $asState) -match '^as ')) {
        Write-Host 'ok   ... removing its slots and forgetting the idle clock'
    } else { Write-Host "FAIL ... removing its slots and forgetting the idle clock: $(@(Get-PoolSlotDirs -PoolDir $asDir).Count) slot(s) left"; $fails++ }
    if ((Get-PoolConfLine -ConfPath $confPath -Name 'as').Count -eq 1) {
        Write-Host 'ok   autoscale never rewrites windows-pools.conf'
    } else { Write-Host 'FAIL autoscale never rewrites windows-pools.conf'; $fails++ }

    Set-Content -Path $asConf -Value 'as 1 3 0'
    New-Slot -PoolDir $asDir -Index 1 | Out-Null
    Check-Wp 'autoscale raises a pool below min' 0 'as: 0 running, 0 busy, 0 queued -> 1 (below min 1)' @('autoscale', '-Once', '-HostLabel', 'H')
    $minPid = Join-Path $asDir 'slot-1\.pid'
    if (Test-Path $minPid) { [void](Register-SlotPidFile $minPid); Write-Host 'ok   ... starting its slot' }
    else { Write-Host 'FAIL ... starting its slot'; $fails++ }
} finally {
    Cleanup
    if ($env:COMPUTERNAME_BACKUP) { $env:COMPUTERNAME = $env:COMPUTERNAME_BACKUP }
}

if ($fails -gt 0) {
    Write-Host "$fails check(s) failed"
    exit 1
}
Write-Host 'all checks passed'
