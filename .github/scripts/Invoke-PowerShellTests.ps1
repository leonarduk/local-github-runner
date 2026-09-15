<#
.SYNOPSIS
    Runs every tests\*_test.ps1 in this repo under the PowerShell that is
    running this script, and fails if any of them fails. Meant to be run
    under BOTH `powershell` (Windows PowerShell 5.1) and `pwsh` (7+);
    .github\workflows\powershell-tests.yml does exactly that.

.EXAMPLE
    powershell -NoProfile -File .\.github\scripts\Invoke-PowerShellTests.ps1
    pwsh       -NoProfile -File .\.github\scripts\Invoke-PowerShellTests.ps1

.NOTES
    Why this runs the tests at all when Test-PowerShellParses.ps1 already
    covers both shells: that check parses and never executes, so, as its
    own header says, a cmdlet or parameter that exists in 7 and not in 5.1
    passes it and still fails at runtime. Running the tests under 5.1 is
    what catches that class of bug, at least for the code they reach.

    Discovered by glob, not listed: a test added without anyone also
    remembering to edit a workflow is how these tests went unrun in the
    first place.

    Each test runs in its own child process of this same shell,
    `-File`, exactly as windows\README.md tells a person to run it,
    rather than in-process with `&`, for three reasons:
      - Tests set process-wide state ($env:PSModulePath, $env:COMPUTERNAME,
        fake-gh switches), and one test's leftovers must not be the next
        one's starting conditions.
      - A test that passes may just fall off the end without `exit 0`.
        In-process, $LASTEXITCODE would then still hold the exit code of
        the last native command that test ran. A child process's exit
        code is 0 for "ran to the end", the argument to `exit`, or 1 for
        an uncaught terminating error, which is the verdict we want.
      - A test's `exit 1`, or an uncaught throw under
        $ErrorActionPreference = 'Stop', ends that test and nothing else,
        so every test still runs and reports.

    (Get-Process -Id $PID).Path is the executable running this script:
    powershell.exe in the 5.1 step and pwsh.exe in the 7 step. That makes
    it impossible for the "5.1" step to quietly run its tests under 7
    just because pwsh is the first shell on PATH.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$shell = (Get-Process -Id $PID).Path

Write-Host ("Testing under PowerShell {0} {1} ({2})" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, $shell)
Write-Host ("Repo root: {0}" -f $root)
Write-Host ''

$tests = @(Get-ChildItem -Path (Join-Path $root 'tests') -Filter '*_test.ps1' -File | Sort-Object Name)

# A glob that matches nothing has to be an error. Otherwise a moved tests\
# directory or a renamed convention turns this into a check that always
# passes because it ran nothing.
if ($tests.Count -eq 0) {
    throw "no tests\*_test.ps1 found under $root -- run this from a checkout of the repo"
}

$failed = New-Object System.Collections.ArrayList
foreach ($test in $tests) {
    $rel = $test.FullName.Substring($root.Length + 1)
    # One collapsible group per test in the Actions log.
    Write-Host ("::group::{0}" -f $rel)
    & $shell -NoProfile -ExecutionPolicy Bypass -File $test.FullName
    $code = $LASTEXITCODE
    Write-Host '::endgroup::'

    if ($code -ne 0) {
        [void]$failed.Add($rel)
        Write-Host ("FAIL  {0} (exit {1})" -f $rel, $code)
    }
    else {
        Write-Host ("ok    {0}" -f $rel)
    }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host ("{0} of {1} test script(s) failed under PowerShell {2} {3}: {4}" -f $failed.Count, $tests.Count, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, ($failed -join ', '))
    exit 1
}

Write-Host ("{0} test script(s) passed under PowerShell {1} {2}." -f $tests.Count, $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)

# Explicit for the same reason as Test-PowerShellParses.ps1: the caller
# reads $LASTEXITCODE, and falling off the end would leave it holding the
# last test's exit code, not this script's verdict.
exit 0
