<#
.SYNOPSIS
    Parses every .ps1 in this repo and fails if any of them has a syntax
    error. Meant to be run under BOTH `powershell` (Windows PowerShell 5.1)
    and `pwsh` (7+); .github\workflows\powershell-parse.yml does exactly that.

.EXAMPLE
    powershell -NoProfile -File .\.github\scripts\Test-PowerShellParses.ps1
    pwsh       -NoProfile -File .\.github\scripts\Test-PowerShellParses.ps1

.NOTES
    Why the 5.1 pass matters: Start-RunnerPool.ps1 launches runner-loop.ps1
    via `pwsh` when it is on PATH and falls back to `powershell.exe` when it
    is not, because pwsh is absent from a stock Windows install. That
    fallback holds only for as long as every script here still parses under
    5.1, and until this check existed nothing verified that.

    7-only syntax -- `??`, `?.`, the `cond ? a : b` ternary, `&&`/`||`
    between commands, `ConvertFrom-Json -AsHashtable`,
    `ForEach-Object -Parallel` -- is a *syntax* error under 5.1, not a
    runtime one, so not one line of the file runs. The symptom is a runner
    slot that never comes online and a slot log that is completely empty:
    the shell rejected the file before the first statement, so there was
    nothing left to write the failure down. It looks like nothing happened,
    not like something broke. And it is invisible on any dev box with pwsh
    installed -- it bites only the stock-Windows hosts the fallback exists
    to serve.

    Parse only, deliberately: this never executes a script. So it will not
    catch a cmdlet or a parameter that exists in 7 and not in 5.1 --
    `Get-Content -AsByteStream` sails through here and still fails at
    runtime. Syntax is the class of breakage that strands a whole fleet
    silently; that is the class this catches.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Write-Host ("Parsing under PowerShell {0} {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
Write-Host ("Repo root: {0}" -f $root)
Write-Host ''

# windows\runners\ holds downloaded actions-runner installs and the per-slot
# working directories -- third-party .ps1 files that are not ours to fix. It
# is gitignored so it never exists in CI, but excluding it explicitly is what
# makes this command mean the same thing on a host with pools running, where
# it would otherwise fail on someone else's code.
$scripts = Get-ChildItem -Path $root -Recurse -Filter '*.ps1' -File |
    Where-Object {
        $rel = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        -not ($rel -like 'windows/runners/*' -or $rel -like '.git/*')
    } |
    Sort-Object FullName

if (-not $scripts) {
    throw "no .ps1 files found under $root -- run this from a checkout of the repo"
}

$failed = 0
foreach ($script in $scripts) {
    $rel = $script.FullName.Substring($root.Length + 1)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors) | Out-Null

    if ($errors.Count -gt 0) {
        $failed++
        Write-Host ("FAIL  {0}" -f $rel)
        # Every error from every file, rather than stopping at the first:
        # one 7-ism usually cascades into several parse errors, and fixing
        # them one CI round-trip at a time is the slow way to do it.
        foreach ($parseError in $errors) {
            Write-Host ("        line {0}: {1}" -f $parseError.Extent.StartLineNumber, $parseError.Message)
        }
    }
    else {
        Write-Host ("ok    {0}" -f $rel)
    }
}

Write-Host ''
if ($failed -gt 0) {
    Write-Host ("{0} of {1} script(s) do not parse under PowerShell {2} {3}." -f $failed, $scripts.Count, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
    exit 1
}

Write-Host ("{0} script(s) parse clean under PowerShell {1} {2}." -f $scripts.Count, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)

# Explicit rather than implicit: the caller reads $LASTEXITCODE, and a script
# that just falls off the end leaves it holding whatever the previous command
# in that session set -- which is how a check ends up reporting someone
# else's result.
exit 0
