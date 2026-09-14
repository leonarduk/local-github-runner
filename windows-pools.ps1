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

.NOTES
    PowerShell 5.1 compatible on purpose -- see PoolSlot.ps1's header. Every
    .ps1 this script dot-sources or calls synchronously has to stay that
    way too, since a host with no `pwsh` runs this dispatcher directly
    under powershell.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('up', 'down', 'reset', 'list', 'start', 'stop', 'restart', 'restart-runner', 'scale', 'declare')]
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
        $poolDir = Join-Path $runnersRoot $name

        # Growing starts slots up to <count> and never touches a running
        # one, so it needs no busy check. Shrinking stops the slots numbered
        # above <count>, and only a busy one of those would lose its job --
        # unlike pools.sh scale, which has to check the whole pool because
        # compose picks which containers go.
        $removing = New-Object System.Collections.ArrayList
        foreach ($slotDir in (Get-PoolSlotDirs -PoolDir $poolDir)) {
            $idx = Get-SlotIndex -SlotName $slotDir.Name
            if ($null -ne $idx -and $idx -gt $count) { [void]$removing.Add($slotDir) }
        }
        if ($removing.Count -gt 0) {
            $running = @($removing | Where-Object { Test-SlotRunning -SlotDir $_.FullName })
            $busyAmong = @($running | ForEach-Object {
                Get-SlotRunnerName -HostLabel $HostLabel -Name $name -Index (Get-SlotIndex -SlotName $_.Name)
            })
            $repo = Get-PoolRepo -PoolDir $poolDir
            if (-not $repo) { $repo = $line.Repo }
            Assert-RunnersIdle -Label "pool '$name'" -Repo $repo -RunnerNames (Get-PoolRunnerNames -PoolDir $poolDir -Name $name) `
                -BusyAmong $busyAmong -HasSlots:($running.Count -gt 0) -Force:$Force
            # Highest first, and gone afterwards rather than left stopped: the
            # way compose removes the containers a smaller --scale drops, so
            # list -Json's slot count is the pool's size again. -Force for the
            # same reason as stop's: an idle runner never exits on its own.
            foreach ($slotDir in ($removing | Sort-Object -Descending { Get-SlotIndex -SlotName $_.Name })) {
                if (Stop-Slot -SlotDir $slotDir.FullName -SlotLabel "$name $($slotDir.Name)" -Force -TimeoutSeconds 10) {
                    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $slotDir.FullName
                    if (Test-Path $slotDir.FullName) {
                        Write-PoolError "stopped $name $($slotDir.Name) but couldn't delete $($slotDir.FullName) -- something still has files open in it"
                    }
                }
            }
        }
        if ($count -gt 0) {
            & (Join-Path $windowsDir 'Start-RunnerPool.ps1') -Name $name -Repo $line.Repo -Count $count `
                -PatFile $PatFile -HostLabel $HostLabel -RunnerVersion $RunnerVersion -Arch $Arch
            if ($LASTEXITCODE) { exit $LASTEXITCODE }
        }
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
