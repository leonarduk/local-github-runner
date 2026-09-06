<#
.SYNOPSIS
    Windows equivalent of entrypoint.sh: register an ephemeral runner, run
    exactly one job, deregister, repeat. Run this in the background, one
    process per slot -- Start-RunnerPool.ps1 does that for you.

.NOTES
    The Linux side gets per-job isolation for free from the container being
    thrown away after each run. There is no container here, so this script
    only approximates that: it wipes the slot's _work directory before each
    registration. Anything a job left on PATH, in the registry, or installed
    system-wide (chocolatey packages, MSI installs) is NOT undone -- know
    that before trusting this the way the Linux pool is trusted. See
    windows/README.md, "What this does not give you".

    Stopping: this script has no signal to catch the way entrypoint.sh traps
    SIGTERM, because a hidden background process on Windows has no console
    to deliver one to. Stop-RunnerPool.ps1 instead drops a stop-file next to
    the slot and this loop checks for it between jobs; a job already running
    when the stop-file appears is left to finish rather than killed, unless
    Stop-RunnerPool.ps1 is told to force it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$RunnerDir,
    [Parameter(Mandatory)] [string]$Repo,
    [Parameter(Mandatory)] [string]$PatFile,
    [Parameter(Mandatory)] [string]$RunnerName,
    [string]$Labels = 'self-hosted,windows,x64',
    [string]$RunnerGroup = 'Default',
    [string]$GitHubUrl = 'https://github.com',
    [string]$ApiUrl = 'https://api.github.com',
    [Parameter(Mandatory)] [string]$StopFile
)

$ErrorActionPreference = 'Stop'

function Log($msg) { Write-Host "runner-loop [$RunnerName]: $msg" }
function Fail($msg) { Write-Error "runner-loop [$RunnerName]: $msg"; exit 1 }

if (-not (Test-Path $PatFile)) { Fail "PAT file not found: $PatFile" }
$pat = (Get-Content -Raw $PatFile).Trim()
if (-not $pat) { Fail "PAT file is empty: $PatFile" }

Set-Location $RunnerDir
if (-not (Test-Path '.\config.cmd')) { Fail "no config.cmd in $RunnerDir -- run Install-Runner.ps1 first" }

function Invoke-RunnerApi {
    param([string]$Suffix)
    $headers = @{
        Authorization        = "Bearer $pat"
        Accept               = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    Invoke-RestMethod -Method Post -Uri "$ApiUrl/repos/$Repo/actions/runners/$Suffix" -Headers $headers
}

function Remove-StaleConfig {
    # Mirrors entrypoint.sh's stale-config cleanup: a slot killed mid-job
    # (task killed, host crashed) leaves .runner/.credentials behind, and
    # config.cmd refuses to reconfigure over them.
    if (Test-Path '.runner') {
        Log 'found a stale runner configuration from an earlier run; clearing it'
        try {
            $removal = Invoke-RunnerApi -Suffix 'remove-token'
            & .\config.cmd remove --token $removal.token 2>&1 | ForEach-Object { Log $_ }
        } catch {
            Log "config.cmd remove failed on stale config; deleting local files by hand: $_"
        }
        Remove-Item -Force -ErrorAction SilentlyContinue .runner, .credentials, .credentials_rsaparams
    }
}

function Reset-Workspace {
    $work = Join-Path $RunnerDir '_work'
    if (Test-Path $work) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $work
    }
}

while (-not (Test-Path $StopFile)) {
    Remove-StaleConfig
    Reset-Workspace

    Log "requesting a registration token for $Repo"
    $reg = Invoke-RunnerApi -Suffix 'registration-token'
    if (-not $reg.token) { Fail 'registration-token response contained no token' }

    Log "configuring $RunnerName"
    & .\config.cmd `
        --unattended `
        --ephemeral `
        --disableupdate `
        --url "$GitHubUrl/$Repo" `
        --token $reg.token `
        --name $RunnerName `
        --labels $Labels `
        --runnergroup $RunnerGroup `
        --work _work 2>&1 | ForEach-Object { Log $_ }

    if (-not (Test-Path '.runner')) { Fail 'config.cmd did not produce a .runner file -- registration failed' }

    Log 'waiting for a job'
    $proc = Start-Process -FilePath '.\run.cmd' -NoNewWindow -PassThru

    # Poll rather than just Wait-Process, so a stop-file dropped mid-job is
    # noticed promptly instead of only after the job finishes.
    while (-not $proc.HasExited) {
        if (Test-Path $StopFile) {
            Log 'stop requested while a job may be running; leaving it to finish (see windows/README.md)'
        }
        Start-Sleep -Seconds 2
    }
    Log "run.cmd exited with code $($proc.ExitCode)"

    # --ephemeral deregisters itself server-side on a normal completion, so
    # this is expected to be a no-op on the happy path -- same as
    # entrypoint.sh's deregister(), and tolerated the same way.
    if (Test-Path '.runner') {
        try {
            $removal = Invoke-RunnerApi -Suffix 'remove-token'
            & .\config.cmd remove --token $removal.token 2>&1 | ForEach-Object { Log $_ }
        } catch {
            Log "deregistration failed (expected if the ephemeral job already consumed it): $_"
        }
    }
}

Log 'stop-file present; exiting'
Remove-Item -Force -ErrorAction SilentlyContinue $StopFile
