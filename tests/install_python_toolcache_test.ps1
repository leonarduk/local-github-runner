<#
.SYNOPSIS
    Exercises Install-PythonToolCache.ps1's helper functions: packed MSI
    product-code decoding, the stale-registration verdict, and reading an
    installer log for packages it found already Present.

.NOTES
    Dot-sources the script, which defines its functions and returns before
    downloading or installing anything. Nothing here reads or writes the
    registry or runs an installer: Get-PythonUserRegistration and the
    install itself are left to a real run, and every function tested
    takes its inputs as parameters.

    Run with `pwsh -File tests\install_python_toolcache_test.ps1`, or
    `powershell.exe -File tests\install_python_toolcache_test.ps1`.
#>
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("install_python_toolcache_test_" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$fails = 0

function Check {
    param([string]$Desc, $Got, $Want)
    if ("$Got" -eq "$Want") { Write-Host "ok   $Desc" }
    else { Write-Host "FAIL ${Desc}: got '$Got', want '$Want'"; $script:fails = $script:fails + 1 }
}

try {
    . (Join-Path $repoRoot 'windows\Install-PythonToolCache.ps1')

    # ---- ConvertFrom-PackedGuid ----
    # The two products removed by hand on 2026-09-15, packed as they appear
    # under HKCU:\Software\Microsoft\Installer\Products.
    Check 'ConvertFrom-PackedGuid decodes Core Interpreter' (ConvertFrom-PackedGuid -Packed 'B210470B58B99404AB105AA8C8C42263') '{B074012B-9B85-4049-BA01-A58A8C4C2236}'
    Check 'ConvertFrom-PackedGuid decodes Executables' (ConvertFrom-PackedGuid -Packed 'c987830c5bcd3d24c815b39cdd2bb609') '{C038789C-DCB5-42D3-8C51-3BC9DDB26B90}'
    Check 'ConvertFrom-PackedGuid rejects a non-GUID key' ($null -eq (ConvertFrom-PackedGuid -Packed 'not-a-guid')) $true

    # ---- Get-RegistrationVerdict ----
    $versionDir = Join-Path $tmp 'toolcache\Python\3.11.9\x64'
    $wiped = Join-Path $tmp 'slot-1\_work\_tool\Python\3.11.9\x64'
    $live = Join-Path $tmp 'Programs\Python311'
    New-Item -ItemType Directory -Force -Path $live | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $live 'python.exe') | Out-Null

    Check 'verdict: nothing registered installs as normal' (Get-RegistrationVerdict -InstallPath $null -ProductCount 0 -VersionDir $versionDir) 'none'
    Check 'verdict: an InstallPath alone, with no products, installs as normal' (Get-RegistrationVerdict -InstallPath $live -ProductCount 0 -VersionDir $versionDir) 'none'
    Check 'verdict: products with no InstallPath are removed' (Get-RegistrationVerdict -InstallPath $null -ProductCount 2 -VersionDir $versionDir) 'remove'
    Check 'verdict: a registration into a wiped _work is removed' (Get-RegistrationVerdict -InstallPath $wiped -ProductCount 2 -VersionDir $versionDir) 'remove'
    Check 'verdict: a registration at the cache dir itself is removed' (Get-RegistrationVerdict -InstallPath ($versionDir.ToUpperInvariant() + '\') -ProductCount 2 -VersionDir $versionDir) 'remove'
    Check 'verdict: a working install elsewhere is refused' (Get-RegistrationVerdict -InstallPath $live -ProductCount 2 -VersionDir $versionDir) 'refuse'

    # ---- Get-PresentUserPackages ----
    $skippedLog = Join-Path $tmp 'skipped.log'
    Set-Content -Path $skippedLog -Value @(
        '[8134:B0F4][2026-09-15T05:36:50]i101: Detected package: core_AllUsers, state: Absent, cached: None'
        '[8134:B0F4][2026-09-15T05:36:50]i101: Detected package: core_JustForMe, state: Present, cached: Complete'
        '[8134:B0F4][2026-09-15T05:36:50]i101: Detected package: exe_JustForMe, state: Present, cached: Complete'
        '[8134:B0F4][2026-09-15T05:36:50]i104: Detected package: exe_JustForMe, feature: DefaultFeature, state: Local'
        '[8134:B0F4][2026-09-15T05:36:50]i101: Detected package: dev_JustForMe, state: Absent, cached: Complete'
    )
    Check 'Get-PresentUserPackages lists the packages found Present' ((Get-PresentUserPackages -LogPath $skippedLog) -join ',') 'core_JustForMe,exe_JustForMe'
    $cleanLog = Join-Path $tmp 'clean.log'
    Set-Content -Path $cleanLog -Value '[8134:B0F4][2026-09-07T06:21:02]i101: Detected package: core_JustForMe, state: Absent, cached: None'
    Check 'Get-PresentUserPackages is empty for a clean install' @(Get-PresentUserPackages -LogPath $cleanLog).Count 0
    Check 'Get-PresentUserPackages is empty for a missing log' @(Get-PresentUserPackages -LogPath (Join-Path $tmp 'nope.log')).Count 0

    # ---- Find-InstallerLog ----
    $logDir = Join-Path $tmp 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $older = Join-Path $logDir 'Python 3.11.9 (64-bit)_20260914094132.log'
    $newer = Join-Path $logDir 'Python 3.11.9 (64-bit)_20260915053649.log'
    $pkg = Join-Path $logDir 'Python 3.11.9 (64-bit)_20260915053649_000_core_JustForMe.log'
    foreach ($f in $older, $newer, $pkg) { New-Item -ItemType File -Force -Path $f | Out-Null }
    (Get-Item $older).LastWriteTime = (Get-Date).AddHours(-2)
    (Get-Item $newer).LastWriteTime = (Get-Date).AddHours(-1)
    Check 'Find-InstallerLog prefers the log it asked for' (Find-InstallerLog -Preferred $skippedLog -Version '3.11.9' -Bits '64-bit' -SearchDir $logDir) $skippedLog
    Check 'Find-InstallerLog falls back to the newest bundle log, not a package log' (Find-InstallerLog -Preferred (Join-Path $tmp 'nope.log') -Version '3.11.9' -Bits '64-bit' -SearchDir $logDir) $newer
    Check 'Find-InstallerLog is null with nothing to find' ($null -eq (Find-InstallerLog -Version '3.12.10' -Bits '64-bit' -SearchDir $logDir)) $true
} finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}

if ($fails -gt 0) {
    Write-Host "$fails check(s) failed"
    exit 1
}
Write-Host 'all checks passed'
