<#
.SYNOPSIS
    Windows equivalent of pools.sh, for the native (non-container) runner
    pools under windows\runners\. Same commands, same shape of output.

.EXAMPLE
    .\windows-pools.ps1 up jobtrack leonarduk/jobtrack 2
    .\windows-pools.ps1 down jobtrack
    .\windows-pools.ps1 reset jobtrack leonarduk/jobtrack 2
    .\windows-pools.ps1 list
    .\windows-pools.ps1 list -Json
    .\windows-pools.ps1 list -Json jobtrack
    .\windows-pools.ps1 start jobtrack
    .\windows-pools.ps1 stop jobtrack
    .\windows-pools.ps1 stop jobtrack -Force
    .\windows-pools.ps1 restart jobtrack
    .\windows-pools.ps1 restart-runner HOST-HOST-jobtrack-slot1
    .\windows-pools.ps1 scale jobtrack 3
    .\windows-pools.ps1 scale jobtrack 1 -Force
    .\windows-pools.ps1 declare jobtrack leonarduk/jobtrack 1
    .\windows-pools.ps1 autoscale -Once -DryRun
    .\windows-pools.ps1 autoscale -Interval 120

.NOTES
    PowerShell 5.1 compatible on purpose -- see PoolSlot.ps1's header. Every
    .ps1 this script dot-sources or calls synchronously has to stay that
    way too, since a host with no `pwsh` runs this dispatcher directly
    under powershell.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('up', 'down', 'reset', 'list', 'start', 'stop', 'restart', 'restart-runner', 'scale', 'declare', 'autoscale')]
    [string]$Command,

    # up/reset/declare: Name, Repo, Count. down/start/stop/restart: Name (Arg1
    # only). restart-runner: Arg1 is the runner name. scale: Name, Count
    # (Arg1, Arg2). list -Json: every positional argument
    # (Arg1/Arg2/Arg3/Rest) is a pool name to filter to.
    [Parameter(Position = 1)] [string]$Arg1,
    [Parameter(Position = 2)] [string]$Arg2,
    [Parameter(Position = 3)] [string]$Arg3,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]]$Rest,

    [switch]$Json,
    [switch]$Force,
    # autoscale: one pass and exit, print without acting, seconds between passes.
    [switch]$Once,
    [switch]$DryRun,
    [ValidateRange(1, 86400)] [int]$Interval = 60,
    [string]$HostLabel = $env:COMPUTERNAME,
    [string]$PatFile,
    [string]$RunnerVersion = '2.337.0',
    [ValidateSet('x64', 'arm64')] [string]$Arch = 'x64'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$windowsDir = Join-Path $here 'windows'
$runnersRoot = Join-Path $windowsDir 'runners'
$confPath = Join-Path $here 'windows-pools.conf'
$autoscaleConfPath = Join-Path $here 'windows-autoscale.conf'
# "<name> <epoch>" per pool idle above its min, and since when.
$autoscaleStatePath = Join-Path $here '.windows-autoscale-state'
$scriptPath = $MyInvocation.MyCommand.Path
if (-not $PatFile) { $PatFile = Join-Path $here 'pat.secret' }

. (Join-Path $windowsDir 'PoolSlot.ps1')

# Every positional name given after the command, for `list -Json
# [<name>...]` -- Arg1/Arg2/Arg3 exist so up/reset/stop/etc. get typed
# positions, but list -Json wants an open-ended list, so all four are
# pooled together here instead.
function Get-PositionalNames {
    $names = New-Object System.Collections.ArrayList
    foreach ($v in @($Arg1, $Arg2, $Arg3)) {
        if ($v) { [void]$names.Add($v) }
    }
    if ($Rest) {
        foreach ($v in $Rest) { if ($v) { [void]$names.Add($v) } }
    }
    return $names.ToArray()
}

function Invoke-ListJson {
    param([string[]]$Names)

    $poolNames = New-Object System.Collections.ArrayList
    if ($Names -and $Names.Count -gt 0) {
        foreach ($n in $Names) { [void]$poolNames.Add($n) }
    } else {
        foreach ($cl in (Get-PoolConfLines -ConfPath $confPath)) { [void]$poolNames.Add($cl.Name) }
        if (Test-Path $runnersRoot) {
            foreach ($d in (Get-ChildItem -Path $runnersRoot -Directory -ErrorAction SilentlyContinue)) {
                if (-not ($poolNames -contains $d.Name)) { [void]$poolNames.Add($d.Name) }
            }
        }
    }

    $pools = New-Object System.Collections.ArrayList
    foreach ($name in $poolNames) {
        $poolDir = Join-Path $runnersRoot $name
        $isDeclared = [bool](Get-PoolConfLine -ConfPath $confPath -Name $name)
        $hasSlots = (Get-PoolSlotDirs -PoolDir $poolDir).Count -gt 0
        # Only reachable when a name was passed explicitly (the "no names"
        # branch above only ever adds declared or actually-present pools).
        if (-not $isDeclared -and -not $hasSlots) { continue }
        [void]$pools.Add((Get-PoolStatusObject -Name $name -RunnersRoot $runnersRoot -ConfPath $confPath -HostLabel $HostLabel))
    }

    if ($pools.Count -eq 0) {
        Write-Output '[]'
        return
    }
    ConvertTo-Json -InputObject $pools.ToArray() -Depth 6
}

# All expected runner names for a pool's slots as currently on disk --
# whether running or not, mirroring pools.sh's pool_cids() (`docker ps -a`,
# not just running containers).
function Get-PoolRunnerNames {
    param([string]$PoolDir, [string]$Name)
    $names = New-Object System.Collections.ArrayList
    foreach ($slotDir in (Get-PoolSlotDirs -PoolDir $PoolDir)) {
        $idx = Get-SlotIndex -SlotName $slotDir.Name
        if ($null -eq $idx) { continue }
        [void]$names.Add((Get-SlotRunnerName -HostLabel $HostLabel -Name $Name -Index $idx))
    }
    return $names.ToArray()
}

# Resizes declared pool <Name> (its windows-pools.conf line is <Line>) to
# <Count> running slots: stops and removes the slots numbered above <Count>,
# then starts slots 1..<Count>. Returns $null, or -- when a slot it would
# stop is busy or can't be confirmed idle, and not -Force -- the reason, with
# nothing changed. Leaves windows-pools.conf alone.
function Invoke-PoolResize {
    param([string]$Name, $Line, [int]$Count, [switch]$Force)
    $poolDir = Join-Path $runnersRoot $Name
    # Growing starts slots up to <count> and never touches a running
    # one, so it needs no busy check. Shrinking stops the slots numbered
    # above <count>, and only a busy one of those would lose its job --
    # unlike pools.sh scale, which has to check the whole pool because
    # compose picks which containers go.
    $removing = New-Object System.Collections.ArrayList
    foreach ($slotDir in (Get-PoolSlotDirs -PoolDir $poolDir)) {
        $idx = Get-SlotIndex -SlotName $slotDir.Name
        if ($null -ne $idx -and $idx -gt $Count) { [void]$removing.Add($slotDir) }
    }
    if ($removing.Count -gt 0) {
        $running = @($removing | Where-Object { Test-SlotRunning -SlotDir $_.FullName })
        $busyAmong = @($running | ForEach-Object {
            Get-SlotRunnerName -HostLabel $HostLabel -Name $Name -Index (Get-SlotIndex -SlotName $_.Name)
        })
        $repo = Get-PoolRepo -PoolDir $poolDir
        if (-not $repo) { $repo = $Line.Repo }
        if (-not $Force) {
            $why = Get-RunnersNotIdleReason -Label "pool '$Name'" -Repo $repo `
                -RunnerNames (Get-PoolRunnerNames -PoolDir $poolDir -Name $Name) `
                -BusyAmong $busyAmong -HasSlots:($running.Count -gt 0)
            if ($why) { return $why }
        }
        # Highest first, and gone afterwards rather than left stopped: the
        # way compose removes the containers a smaller --scale drops, so
        # list -Json's slot count is the pool's size again. -Force for the
        # same reason as stop's: an idle runner never exits on its own.
        foreach ($slotDir in ($removing | Sort-Object -Descending { Get-SlotIndex -SlotName $_.Name })) {
            if (Stop-Slot -SlotDir $slotDir.FullName -SlotLabel "$Name $($slotDir.Name)" -Force -TimeoutSeconds 10) {
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $slotDir.FullName
                if (Test-Path $slotDir.FullName) {
                    Write-PoolError "stopped $Name $($slotDir.Name) but couldn't delete $($slotDir.FullName) -- something still has files open in it"
                }
            }
        }
    }
    if ($Count -gt 0) {
        $global:LASTEXITCODE = 0
        & (Join-Path $windowsDir 'Start-RunnerPool.ps1') -Name $Name -Repo $Line.Repo -Count $Count `
            -PatFile $PatFile -HostLabel $HostLabel -RunnerVersion $RunnerVersion -Arch $Arch | Out-Host
        if ($LASTEXITCODE) { throw "Start-RunnerPool.ps1 exited $LASTEXITCODE for $Name" }
    }
    return $null
}

# One autoscale pass over windows-autoscale.conf's pools -- the Windows
# analogue of pools.sh's autoscale_tick. Every slot carries the same
# self-hosted,windows,<arch>,<host> labels, so a queued job whose labels are
# all among those counts against the first windows-pools.conf pool for its
# repo; a job naming anything else (linux, a GitHub-hosted image, another
# host) counts against nothing here.
function Invoke-AutoscalePass {
    param([switch]$DryRun)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $slotLabels = @('self-hosted', 'windows', $Arch.ToLowerInvariant(), $HostLabel.ToLowerInvariant())
    $declared = @(Get-PoolConfLines -ConfPath $confPath)

    $oldState = @{}
    if (Test-Path $autoscaleStatePath) {
        foreach ($l in (Get-Content $autoscaleStatePath)) {
            $p = [System.Text.RegularExpressions.Regex]::Split($l.Trim(), '\s+')
            if ($p.Count -ge 2 -and $p[1] -match '^\d+$') { $oldState[$p[0]] = [long]$p[1] }
        }
    }
    $newState = New-Object System.Collections.ArrayList

    $entries = New-Object System.Collections.ArrayList
    foreach ($raw in (Get-Content $autoscaleConfPath)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $p = [System.Text.RegularExpressions.Regex]::Split($line, '\s+')
        $name = $p[0]
        $conf = Get-PoolConfLine -ConfPath $confPath -Name $name
        if (-not $conf) { Write-PoolError "${name}: not in windows-pools.conf -- skipped"; continue }
        $idle = '10'
        if ($p.Count -ge 4) { $idle = $p[3] }
        if ($p.Count -lt 3 -or $p[1] -notmatch '^\d+$' -or $p[2] -notmatch '^\d+$' -or $idle -notmatch '^\d+$' -or [int]$p[1] -gt [int]$p[2]) {
            Write-PoolError "${name}: needs <min> <max> [idle_minutes] as integers, min <= max -- skipped"
            continue
        }
        [void]$entries.Add([PSCustomObject]@{ Name = $name; Min = [int]$p[1]; Max = [int]$p[2]; Idle = [int]$idle; Line = $conf })
    }

    foreach ($repo in @($entries | ForEach-Object { $_.Line.Repo } | Sort-Object -Unique)) {
        $repoEntries = @($entries | Where-Object { $_.Line.Repo -eq $repo })
        $jobs = Get-QueuedJobLabelSets -Repo $repo
        $runners = $null
        if ($null -ne $jobs) { $runners = Get-GhRunnersForRepo -Repo $repo }
        if ($null -eq $jobs -or $null -eq $runners) {
            foreach ($e in $repoEntries) {
                Write-PoolError "$($e.Name): could not ask GitHub about $repo -- left as it is"
                # An outage says nothing about whether it's idle.
                if ($oldState.ContainsKey($e.Name)) { [void]$newState.Add("$($e.Name) $($oldState[$e.Name])") }
            }
            continue
        }

        $owner = @($declared | Where-Object { $_.Repo -eq $repo })[0].Name
        $queuedHere = 0
        foreach ($job in $jobs) {
            $fits = $true
            foreach ($l in $job) { if ($slotLabels -notcontains $l) { $fits = $false; break } }
            if ($fits) { $queuedHere++ }
        }

        foreach ($e in $repoEntries) {
            $poolDir = Join-Path $runnersRoot $e.Name
            $current = 0
            $busy = 0
            foreach ($slotDir in (Get-PoolSlotDirs -PoolDir $poolDir)) {
                if (-not (Test-SlotRunning -SlotDir $slotDir.FullName)) { continue }
                $current++
                $idx = Get-SlotIndex -SlotName $slotDir.Name
                if ($null -eq $idx) { continue }
                $r = Find-RunnerByName -Runners $runners -Name (Get-SlotRunnerName -HostLabel $HostLabel -Name $e.Name -Index $idx)
                if ($r -and $r.busy) { $busy++ }
            }
            $queued = 0
            if ($e.Name -eq $owner) { $queued = $queuedHere }
            $need = [Math]::Min($busy + $queued, $e.Max)
            $target = $current
            $reason = 'steady'
            $since = $now
            if ($current -lt $e.Min) { $target = $e.Min; $reason = "below min $($e.Min)" }
            if ($need -gt $target) {
                $target = $need
                $reason = "$queued queued, $busy busy"
            } elseif ($queued -gt 0 -and $need -eq $e.Max -and $target -eq $current) {
                $reason = "$queued queued, but at max $($e.Max)"
            }
            if ($target -eq $current -and $queued -eq 0 -and $busy -eq 0 -and $current -gt $e.Min) {
                if ($oldState.ContainsKey($e.Name)) { $since = $oldState[$e.Name] }
                if ($now - $since -ge $e.Idle * 60) {
                    $target = $e.Min
                    $reason = "idle $($e.Idle)m"
                } else {
                    [void]$newState.Add("$($e.Name) $since")
                    $reason = "idle, down to $($e.Min) in $($e.Idle * 60 - ($now - $since))s"
                }
            }
            Write-Host "$($e.Name): $current running, $busy busy, $queued queued -> $target ($reason)"
            if ($DryRun -or $target -eq $current) { continue }
            try {
                $why = Invoke-PoolResize -Name $e.Name -Line $e.Line -Count $target
                if ($why) {
                    Write-PoolError "$($e.Name): not shrinking after all -- $why"
                    [void]$newState.Add("$($e.Name) $since")
                }
            } catch {
                Write-PoolError "$($e.Name): resize to $target failed -- $_"
            }
        }
    }

    if (-not $DryRun) { [System.IO.File]::WriteAllLines($autoscaleStatePath, [string[]]$newState.ToArray()) }
}

switch ($Command) {
    'up' {
        $name = $Arg1
        $repo = $Arg2
        if (-not $name -or -not $repo) { throw 'usage: .\windows-pools.ps1 up <name> <owner/repo> [count]' }
        $count = 2
        if ($Arg3) { $count = [int]$Arg3 }
        & (Join-Path $windowsDir 'Start-RunnerPool.ps1') -Name $name -Repo $repo -Count $count `
            -PatFile $PatFile -HostLabel $HostLabel -RunnerVersion $RunnerVersion -Arch $Arch
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
    }
    'down' {
        $name = $Arg1
        if (-not $name) { throw 'usage: .\windows-pools.ps1 down <name>' }
        & (Join-Path $windowsDir 'Stop-RunnerPool.ps1') -Name $name
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
    }
    'reset' {
        $name = $Arg1
        $repo = $Arg2
        if (-not $name -or -not $repo) { throw 'usage: .\windows-pools.ps1 reset <name> <owner/repo> [count]' }
        $count = 2
        if ($Arg3) { $count = [int]$Arg3 }
        & (Join-Path $windowsDir 'Stop-RunnerPool.ps1') -Name $name -Force -TimeoutSeconds 10
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
        & (Join-Path $windowsDir 'Start-RunnerPool.ps1') -Name $name -Repo $repo -Count $count `
            -PatFile $PatFile -HostLabel $HostLabel -RunnerVersion $RunnerVersion -Arch $Arch
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
    }
    'start' {
        $name = $Arg1
        if (-not $name) { Invoke-PoolDie 'usage: .\windows-pools.ps1 start <name>' }
        $line = Get-PoolConfLine -ConfPath $confPath -Name $name
        if (-not $line) {
            Invoke-PoolDie "no pool named '$name' in windows-pools.conf -- start only brings up pools declared there"
        }
        & (Join-Path $windowsDir 'Start-RunnerPool.ps1') -Name $name -Repo $line.Repo -Count $line.Count `
            -PatFile $PatFile -HostLabel $HostLabel -RunnerVersion $RunnerVersion -Arch $Arch
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
    }
    'stop' {
        $name = $Arg1
        if (-not $name) { Invoke-PoolDie 'usage: .\windows-pools.ps1 stop <name> [-Force]' }
        $poolDir = Join-Path $runnersRoot $name
        $repo = Get-PoolRepo -PoolDir $poolDir
        $runnerNames = Get-PoolRunnerNames -PoolDir $poolDir -Name $name
        $hasSlots = (Get-PoolSlotDirs -PoolDir $poolDir).Count -gt 0
        Assert-RunnersIdle -Label "pool '$name'" -Repo $repo -RunnerNames $runnerNames -HasSlots:$hasSlots -Force:$Force
        # Already confirmed idle (or -Force): force the local stop too,
        # since an ephemeral runner that isn't mid-job just sits listening
        # for the next job -- it won't exit on its own inside
        # Stop-RunnerPool.ps1's wait loop the way a mid-job one eventually
        # does. See windows/README.md.
        & (Join-Path $windowsDir 'Stop-RunnerPool.ps1') -Name $name -Force -TimeoutSeconds 10
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
    }
    'restart' {
        $name = $Arg1
        if (-not $name) { Invoke-PoolDie 'usage: .\windows-pools.ps1 restart <name> [-Force]' }
        $line = Get-PoolConfLine -ConfPath $confPath -Name $name
        if (-not $line) {
            Invoke-PoolDie "no pool named '$name' in windows-pools.conf -- restart only works on pools declared there, since it has to start it again"
        }
        $poolDir = Join-Path $runnersRoot $name
        $repo = Get-PoolRepo -PoolDir $poolDir
        if (-not $repo) { $repo = $line.Repo }
        $runnerNames = Get-PoolRunnerNames -PoolDir $poolDir -Name $name
        $hasSlots = (Get-PoolSlotDirs -PoolDir $poolDir).Count -gt 0
        Assert-RunnersIdle -Label "pool '$name'" -Repo $repo -RunnerNames $runnerNames -HasSlots:$hasSlots -Force:$Force
        & (Join-Path $windowsDir 'Stop-RunnerPool.ps1') -Name $name -Force -TimeoutSeconds 10
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
        & (Join-Path $windowsDir 'Start-RunnerPool.ps1') -Name $name -Repo $line.Repo -Count $line.Count `
            -PatFile $PatFile -HostLabel $HostLabel -RunnerVersion $RunnerVersion -Arch $Arch
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
    }
    'restart-runner' {
        $runnerName = $Arg1
        if (-not $runnerName) { Invoke-PoolDie 'usage: .\windows-pools.ps1 restart-runner <container> [-Force]' }
        & (Join-Path $windowsDir 'Restart-RunnerSlot.ps1') -RunnerName $runnerName -Force:$Force `
            -RunnersRoot $runnersRoot -HostLabel $HostLabel -PatFile $PatFile -RunnerVersion $RunnerVersion -Arch $Arch
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
    }
    'scale' {
        $name = $Arg1
        $usage = 'usage: .\windows-pools.ps1 scale <name> <count> [-Force]'
        if (-not $name -or -not $Arg2 -or $Arg3 -or $Rest) { Invoke-PoolDie $usage }
        if ($Arg2 -notmatch '^\d+$') { Invoke-PoolDie "$usage -- <count> must be a non-negative integer" }
        $count = [int]$Arg2
        $line = Get-PoolConfLine -ConfPath $confPath -Name $name
        if (-not $line) {
            Invoke-PoolDie "no pool named '$name' in windows-pools.conf -- scale only works on pools declared there"
        }
        $why = Invoke-PoolResize -Name $name -Line $line -Count $count -Force:$Force
        if ($why) { Invoke-PoolRefuse $why }
        # start and restart read the count from windows-pools.conf, so
        # without this the next one would quietly undo the scale.
        $old = Set-PoolConfCount -ConfPath $confPath -Name $name -Count $count
        if ($null -ne $old) { Write-Host "windows-pools.conf now declares $name at $count (was $old)" }
    }
    'declare' {
        # Adds a windows-pools.conf line for a pool it doesn't have yet, so
        # start, restart and scale can bring it up. Starts nothing.
        $name = $Arg1
        $repo = $Arg2
        $usage = 'usage: .\windows-pools.ps1 declare <name> <owner/repo> [count]'
        if (-not $name -or -not $repo -or $Rest) { Invoke-PoolDie $usage }
        # The names pools.sh takes, so one name is one pool on either side.
        if ($name -cnotmatch '^[a-z0-9][a-z0-9_-]{0,99}$') {
            Invoke-PoolDie "$usage -- <name> must be lowercase letters, digits, - and _"
        }
        if ($repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            Invoke-PoolDie "$usage -- <owner/repo> must look like owner/repo"
        }
        $count = 1
        if ($Arg3) {
            if ($Arg3 -notmatch '^\d+$') { Invoke-PoolDie "$usage -- [count] must be a non-negative integer" }
            $count = [int]$Arg3
        }
        if (Get-PoolConfLine -ConfPath $confPath -Name $name) {
            Invoke-PoolDie "'$name' is already declared in windows-pools.conf"
        }
        Add-PoolConfLine -ConfPath $confPath -Name $name -Repo $repo -Count $count
        Write-Host "windows-pools.conf now declares $name ($repo) at $count"
    }
    'autoscale' {
        if (-not (Test-Path $autoscaleConfPath)) {
            Invoke-PoolDie 'no windows-autoscale.conf here -- copy windows-autoscale.conf.example and list the pools to autoscale'
        }
        if ($Once) {
            Invoke-AutoscalePass -DryRun:$DryRun
            # A failed gh call (a pool skipped, not a failed pass) leaves
            # $LASTEXITCODE non-zero, which would otherwise become this exit code.
            exit 0
        }
        # Each pass in a child process, so one that dies -- or exits, as the
        # library's die/refuse helpers do -- doesn't end the loop.
        $shellExe = (Get-Process -Id $PID).Path
        $passArgs = @('-NoProfile', '-File', $scriptPath, 'autoscale', '-Once', '-HostLabel', $HostLabel,
            '-PatFile', $PatFile, '-RunnerVersion', $RunnerVersion, '-Arch', $Arch)
        if ($DryRun) { $passArgs += '-DryRun' }
        while ($true) {
            Write-Host "== $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))"
            & $shellExe @passArgs
            if ($LASTEXITCODE) { Write-PoolError "autoscale pass failed (exit $LASTEXITCODE); next in ${Interval}s" }
            Start-Sleep -Seconds $Interval
        }
    }
    'list' {
        if ($Json) {
            Invoke-ListJson -Names (Get-PositionalNames)
            return
        }
        if (-not (Test-Path $runnersRoot)) {
            Write-Host 'no windows pools on this host'
            return
        }
        $pools = Get-ChildItem $runnersRoot -Directory
        if (-not $pools) {
            Write-Host 'no windows pools on this host'
            return
        }
        '{0,-20} {1,-42} {2,-12} {3}' -f 'POOL', 'REPO', 'SLOTS', 'GITHUB' | Write-Host
        foreach ($pool in $pools) {
            $repoFile = Join-Path $pool.FullName '.repo'
            $repo = 'unknown'
            if (Test-Path $repoFile) { $repo = (Get-Content $repoFile).Trim() }

            $slots = Get-ChildItem $pool.FullName -Directory -Filter 'slot-*' -ErrorAction SilentlyContinue
            $total = ($slots | Measure-Object).Count
            $running = 0
            foreach ($slot in $slots) {
                $pidFile = Join-Path $slot.FullName '.pid'
                if ((Test-Path $pidFile) -and (Get-Process -Id (Get-Content $pidFile) -ErrorAction SilentlyContinue)) {
                    $running++
                }
            }

            $online = '?'
            if ($repo -ne 'unknown' -and (Get-Command gh -ErrorAction SilentlyContinue)) {
                try {
                    # GitHub capitalises label names on the way back ("Windows", not
                    # "windows" as passed to --labels), so match case-insensitively.
                    $online = (gh api "repos/$repo/actions/runners" --jq '[.runners[] | select(.status=="online" and ([.labels[].name] | map(ascii_downcase) | index("windows")))] | length' 2>$null)
                    if (-not $online) { $online = '0' }
                } catch { $online = '?' }
            }
            '{0,-20} {1,-42} {2,-12} online={3}' -f $pool.Name, $repo, "$running/$total", $online | Write-Host
        }
    }
}
