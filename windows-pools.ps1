<#
.SYNOPSIS
    Windows equivalent of pools.sh, for the native (non-container) runner
    pools under windows\runners\. Same commands, same shape of output.

.EXAMPLE
    .\windows-pools.ps1 up jobtrack leonarduk/jobtrack 2
    .\windows-pools.ps1 down jobtrack
    .\windows-pools.ps1 reset jobtrack leonarduk/jobtrack 2
    .\windows-pools.ps1 list
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)] [ValidateSet('up', 'down', 'reset', 'list')] [string]$Command,
    [Parameter(Position = 1)] [string]$Name,
    [Parameter(Position = 2)] [string]$Repo,
    [Parameter(Position = 3)] [int]$Count = 2
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$runnersRoot = Join-Path $here 'windows\runners'

switch ($Command) {
    'up' {
        if (-not $Name -or -not $Repo) { throw 'usage: .\windows-pools.ps1 up <name> <owner/repo> [count]' }
        & (Join-Path $here 'windows\Start-RunnerPool.ps1') -Name $Name -Repo $Repo -Count $Count
    }
    'down' {
        if (-not $Name) { throw 'usage: .\windows-pools.ps1 down <name>' }
        & (Join-Path $here 'windows\Stop-RunnerPool.ps1') -Name $Name
    }
    'reset' {
        if (-not $Name -or -not $Repo) { throw 'usage: .\windows-pools.ps1 reset <name> <owner/repo> [count]' }
        & (Join-Path $here 'windows\Stop-RunnerPool.ps1') -Name $Name -Force -TimeoutSeconds 10
        & (Join-Path $here 'windows\Start-RunnerPool.ps1') -Name $Name -Repo $Repo -Count $Count
    }
    'list' {
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
            $repo = if (Test-Path $repoFile) { (Get-Content $repoFile).Trim() } else { 'unknown' }

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
                    $online = (gh api "repos/$repo/actions/runners" --jq '[.runners[] | select(.status=="online" and (.labels[].name=="windows"))] | length' 2>$null)
                    if (-not $online) { $online = '0' }
                } catch { $online = '?' }
            }
            '{0,-20} {1,-42} {2,-12} online={3}' -f $pool.Name, $repo, "$running/$total", $online | Write-Host
        }
    }
}
