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

. (Join-Path $PSScriptRoot 'PoolSlot.ps1')

$poolDir = Join-Path $root "windows\runners\$Name"
$logDir  = Join-Path $poolDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# Remembered so windows-pools.ps1 list can report which repo a pool serves
# without needing it passed in again, the same way pools.sh list reads
# GITHUB_REPOSITORY back out of a container's own environment.
Set-Content -Path (Join-Path $poolDir '.repo') -Value $Repo

# RUNNER_HOST_LABEL, mirrored from the Linux side: names the physical
# machine so GitHub's runner list says which box a job ran on, since this
# hostname is real (not random hex like a container's) but two machines can
# still share a Windows computer name on different LANs.
#
# Prefer PowerShell 7, but fall back to Windows PowerShell 5.1 rather than
# failing outright: `pwsh` is not present on a stock Windows install, and a
# missing-executable error here surfaces only as a slot that never starts,
# with nothing in its log to say why.
#
# The fallback is only safe while runner-loop.ps1 (and PoolSlot.ps1's
# Start-Slot, which does the actual work below) stay 5.1-compatible, so
# keep it that way: no ternary, no `??`/`?.`, no `&&`/`||` between commands,
# no `ConvertFrom-Json -AsHashtable`, no `ForEach-Object -Parallel`. All of
# those parse fine under 7 and are syntax errors under 5.1, which would
# strand every slot on exactly the hosts this fallback exists to serve.
# `[Parser]::ParseFile()` under 5.1 is the cheap way to check after editing.
for ($i = 1; $i -le $Count; $i++) {
    Start-Slot -PoolDir $poolDir -Name $Name -Index $i -Repo $Repo -PatFile $PatFile `
        -HostLabel $HostLabel -WindowsDir $PSScriptRoot -RunnerVersion $RunnerVersion -Arch $Arch
}
