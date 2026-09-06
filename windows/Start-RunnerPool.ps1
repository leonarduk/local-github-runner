<#
.SYNOPSIS
    Windows equivalent of `pools.sh up`: bring up <Count> ephemeral runners
    for one repo, each in its own slot directory under windows\runners\<Name>.

.EXAMPLE
    .\windows\Start-RunnerPool.ps1 -Name jobtrack -Repo leonarduk/jobtrack -Count 2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$Name,
    [Parameter(Mandatory)] [string]$Repo,
    [int]$Count = 2,
    [string]$PatFile,
    [string]$HostLabel = $env:COMPUTERNAME,
    [string]$RunnerVersion = '2.337.0',
    [ValidateSet('x64', 'arm64')] [string]$Arch = 'x64'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot   # repo root, since this file lives in windows\
if (-not $PatFile) { $PatFile = Join-Path $root 'pat.secret' }
if (-not (Test-Path $PatFile)) {
    throw "no PAT file at $PatFile -- see README.md, 'Save the PAT'. The Linux and Windows pools share the same pat.secret."
}

$poolDir = Join-Path $root "windows\runners\$Name"
$logDir  = Join-Path $poolDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
# Remembered so windows-pools.ps1 list can report which repo a pool serves
# without needing it passed in again, the same way pools.sh list reads
# GITHUB_REPOSITORY back out of a container's own environment.
Set-Content -Path (Join-Path $poolDir '.repo') -Value $Repo

for ($i = 1; $i -le $Count; $i++) {
    $slot = Join-Path $poolDir "slot-$i"
    $pidFile  = Join-Path $slot '.pid'
    $stopFile = Join-Path $slot '.stop'

    if (Test-Path $pidFile) {
        $existingPid = Get-Content $pidFile -ErrorAction SilentlyContinue
        if ($existingPid -and (Get-Process -Id $existingPid -ErrorAction SilentlyContinue)) {
            Write-Host "Start-RunnerPool: $Name slot-$i already running (pid $existingPid), skipping"
            continue
        }
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $stopFile

    & (Join-Path $PSScriptRoot 'Install-Runner.ps1') -Path $slot -Version $RunnerVersion -Arch $Arch

    # RUNNER_HOST_LABEL, mirrored from the Linux side: names the physical
    # machine so GitHub's runner list says which box a job ran on, since
    # this hostname is real (not random hex like a container's) but two
    # machines can still share a Windows computer name on different LANs.
    $runnerName = "$HostLabel-$env:COMPUTERNAME-$Name-slot$i"
    $labels = "self-hosted,windows,$Arch,$HostLabel"
    $log = Join-Path $logDir "slot-$i.log"

    $psi = @{
        FilePath     = 'pwsh'
        ArgumentList = @(
            '-NoProfile', '-File', (Join-Path $PSScriptRoot 'runner-loop.ps1'),
            '-RunnerDir', $slot,
            '-Repo', $Repo,
            '-PatFile', $PatFile,
            '-RunnerName', $runnerName,
            '-Labels', $labels,
            '-StopFile', $stopFile
        )
        WindowStyle           = 'Hidden'
        RedirectStandardOutput = $log
        RedirectStandardError  = "$log.err"
        PassThru               = $true
    }
    $proc = Start-Process @psi
    Set-Content -Path $pidFile -Value $proc.Id
    Write-Host "Start-RunnerPool: $Name slot-$i started (pid $($proc.Id)), logging to $log"
}
