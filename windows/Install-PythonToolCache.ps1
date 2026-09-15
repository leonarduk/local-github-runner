<#
.SYNOPSIS
    Pre-populates a persistent RUNNER_TOOL_CACHE with a Python install so
    actions/setup-python finds it already there and skips its own
    download-and-install step.

.NOTES
    Why this exists: actions/setup-python, when the tool cache doesn't
    already have a matching version, downloads a python-versions release
    zip and runs its bundled setup.ps1, which tries to remove old registry
    uninstall entries under HKLM and then run the official python.org
    installer exe. Both steps assume an elevated/admin process. Our runner
    processes run as the logged-in user (see runner-loop.ps1's header), so
    that install fails every time on a cache miss.

    The fix is to make sure it's never a cache miss: install once here,
    per-user (InstallAllUsers=0, so no admin rights needed) into a
    persistent toolcache directory that lives outside any runner slot's
    ephemeral _work, and lay it out the way actions/toolkit expects --
    <cache>\Python\<version>\<arch>\ plus a sibling <arch>.complete marker
    file. Start-Slot (PoolSlot.ps1) points RUNNER_TOOL_CACHE at that
    directory.

    actions/setup-python resolves a version spec like "3.11" against the
    tool cache using a semver range match, not an exact string match, so
    caching the single patch version below satisfies any workflow asking
    for "3.11" or "3.11.x" -- it does not need to be the newest 3.11.z.

    Checksum came from downloading the installer once and hashing it
    ourselves (python.org's release page only publishes MD5s); same
    "refuse to install what we can't verify" spirit as Install-Runner.ps1.

    Existing registrations: the installer is a bundle of per-user MSI
    packages, and it decides what to do from what Windows Installer says is
    registered for this user, not from what's on disk. If this version is
    already registered -- say by a setup-python run that installed into a
    slot's _work\_tool, which runner-loop.ps1 has since wiped -- it plans
    no work, exits 0, and leaves $versionDir empty. So before installing,
    a registration of the same version whose directory has no python.exe
    (or is $versionDir itself, being reinstalled) is uninstalled first; one
    that points at a working Python elsewhere is refused unless
    -RemoveExisting. See windows/README.md, "Language runtimes".

    Dot-sourcing this file defines its functions without installing
    anything, which is how tests\install_python_toolcache_test.ps1 calls
    them.
#>
[CmdletBinding()]
param(
    [string]$ToolCacheDir,
    [string]$Version = '3.11.9',
    [ValidateSet('x64', 'x86')] [string]$Arch = 'x64',
    [string]$Sha256 = '5EE42C4EEE1E6B4464BB23722F90B45303F79442DF63083F05322F1785F5FDDE',
    [switch]$Force,
    # Also uninstall a registration of this version that points at a
    # working Python outside the tool cache, instead of refusing.
    [switch]$RemoveExisting
)

function Get-ReversedString {
    param([string]$Text)
    $chars = $Text.ToCharArray()
    [array]::Reverse($chars)
    return -join $chars
}

# The product code msiexec /x takes ("{B074012B-9B85-...}") for a per-user
# MSI product, from the packed form HKCU:\Software\Microsoft\Installer\Products
# names its key with: the first three GUID groups reversed character by
# character, the last two swapped pair by pair. $null if it isn't one.
function ConvertFrom-PackedGuid {
    param([Parameter(Mandatory)][string]$Packed)
    if ($Packed -notmatch '^[0-9A-Fa-f]{32}$') { return $null }
    $p = $Packed.ToUpperInvariant()
    $tail = ''
    for ($i = 16; $i -lt 32; $i += 2) { $tail += $p.Substring($i + 1, 1) + $p.Substring($i, 1) }
    return '{' + (Get-ReversedString $p.Substring(0, 8)) + '-' + (Get-ReversedString $p.Substring(8, 4)) + '-' +
        (Get-ReversedString $p.Substring(12, 4)) + '-' + $tail.Substring(0, 4) + '-' + $tail.Substring(4) + '}'
}

# What Windows says is installed for this user of Python <Version>/<Arch>:
#   InstallPath -- HKCU\Software\Python\PythonCore\<X.Y>\InstallPath, when
#                  that key's Version is exactly <Version>; else $null
#   Products    -- the component MSI products ("Python 3.11.9 Core
#                  Interpreter (64-bit)", ...) still registered, each with
#                  Name and ProductCode. These are what make the installer
#                  skip; InstallPath is only where they claim to live.
function Get-PythonUserRegistration {
    param([Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Arch)
    $minor = ($Version -split '\.')[0..1] -join '.'
    $coreKey = "HKCU:\Software\Python\PythonCore\$minor"
    $bits = '64-bit'
    if ($Arch -eq 'x86') { $coreKey = "$coreKey-32"; $bits = '32-bit' }

    $installPath = $null
    if ((Test-Path $coreKey) -and (Test-Path "$coreKey\InstallPath")) {
        if ((Get-Item $coreKey).GetValue('Version') -eq $Version) {
            $installPath = (Get-Item "$coreKey\InstallPath").GetValue('')
        }
    }

    $products = New-Object System.Collections.ArrayList
    $productsKey = 'HKCU:\Software\Microsoft\Installer\Products'
    if (Test-Path $productsKey) {
        foreach ($k in (Get-ChildItem $productsKey)) {
            $name = $k.GetValue('ProductName')
            # "Python 3.11.9 * (64-bit)" matches the components but not the
            # bundle's own "Python 3.11.9 (64-bit)", which isn't an MSI.
            if (-not $name -or $name -notlike "Python $Version * ($bits)") { continue }
            $code = ConvertFrom-PackedGuid -Packed $k.PSChildName
            if ($code) { [void]$products.Add([PSCustomObject]@{ Name = $name; ProductCode = $code }) }
        }
    }
    return [PSCustomObject]@{ InstallPath = $installPath; Products = $products.ToArray() }
}

# What to do about an existing registration before installing into
# <VersionDir>:
#   'none'   -- no component products registered; install as normal
#   'remove' -- registered, but stale: no InstallPath, no python.exe where
#               it points (its directory was deleted), or it points at
#               <VersionDir>, which is about to be wiped and reinstalled
#   'refuse' -- registered and working somewhere else: a real install, not
#               this script's to uninstall unasked
function Get-RegistrationVerdict {
    param([string]$InstallPath, [int]$ProductCount, [Parameter(Mandatory)][string]$VersionDir)
    if ($ProductCount -eq 0) { return 'none' }
    if (-not $InstallPath) { return 'remove' }
    $registered = [System.IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    $target = [System.IO.Path]::GetFullPath($VersionDir).TrimEnd('\')
    if ($registered -eq $target) { return 'remove' }
    if (-not (Test-Path (Join-Path $InstallPath 'python.exe'))) { return 'remove' }
    return 'refuse'
}

# The *_JustForMe packages an installer log says were already Present
# before it did anything -- the ones it then planned no work for.
function Get-PresentUserPackages {
    param([Parameter(Mandatory)][string]$LogPath)
    $found = New-Object System.Collections.ArrayList
    if (-not (Test-Path $LogPath)) { return $found.ToArray() }
    foreach ($m in (Select-String -Path $LogPath -Pattern 'Detected package: (\w+_JustForMe), state: Present')) {
        [void]$found.Add($m.Matches[0].Groups[1].Value)
    }
    return $found.ToArray()
}

# <Preferred> if the installer wrote it, else the newest bundle log for
# this version in <SearchDir> ("Python 3.11.9 (64-bit)_<timestamp>.log",
# not the per-package "..._000_core_JustForMe.log" files beside it), else
# $null.
function Find-InstallerLog {
    param([string]$Preferred, [Parameter(Mandatory)][string]$Version, [Parameter(Mandatory)][string]$Bits,
        [string]$SearchDir = $env:TEMP)
    if ($Preferred -and (Test-Path $Preferred)) { return $Preferred }
    $newest = Get-ChildItem -Path $SearchDir -Filter "Python $Version ($Bits)_*.log" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '_\d{14}\.log$' } | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($newest) { return $newest.FullName }
    return $null
}

if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot   # repo root, since this file lives in windows\
if (-not $ToolCacheDir) { $ToolCacheDir = Join-Path $root 'windows\toolcache' }

$versionDir  = Join-Path $ToolCacheDir "Python\$Version\$Arch"
$markerFile  = Join-Path $ToolCacheDir "Python\$Version\$Arch.complete"

if ((Test-Path $markerFile) -and -not $Force) {
    Write-Host "Install-PythonToolCache: $Version ($Arch) already cached at $versionDir, skipping (-Force to reinstall)"
    return
}

$installerArch = if ($Arch -eq 'x64') { 'amd64' } else { '' }
$bits = if ($Arch -eq 'x64') { '64-bit' } else { '32-bit' }
$asset = "python-$Version-$installerArch.exe"
$url   = "https://www.python.org/ftp/python/$Version/$asset"
$installerPath = Join-Path $env:TEMP $asset
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$installLog   = Join-Path $env:TEMP "Install-PythonToolCache_$Version-${Arch}_$stamp.log"
$uninstallLog = Join-Path $env:TEMP "Install-PythonToolCache_$Version-${Arch}_${stamp}_uninstall.log"

Write-Host "Install-PythonToolCache: downloading $url"
Invoke-WebRequest -Uri $url -OutFile $installerPath -UseBasicParsing

$actual = (Get-FileHash -Path $installerPath -Algorithm SHA256).Hash
if ($actual.ToUpperInvariant() -ne $Sha256.ToUpperInvariant()) {
    Remove-Item $installerPath -Force
    throw "Install-PythonToolCache: SHA256 mismatch for $asset -- expected $Sha256, got $actual. Refusing to install a Python build that does not match its published digest."
}

try {
    $reg = Get-PythonUserRegistration -Version $Version -Arch $Arch
    $products = @($reg.Products)
    $where = $reg.InstallPath
    if (-not $where) { $where = '(no InstallPath registered)' }
    $verdict = Get-RegistrationVerdict -InstallPath $reg.InstallPath -ProductCount $products.Count -VersionDir $versionDir

    if ($verdict -eq 'refuse' -and -not $RemoveExisting) {
        throw "Install-PythonToolCache: Python $Version ($bits) is already installed for this user at $($reg.InstallPath). The installer would treat it as installed and put nothing in $versionDir. Uninstall it first (Settings > Apps > 'Python $Version ($bits)'), or rerun with -RemoveExisting to have this script do it."
    }
    if ($verdict -ne 'none') {
        Write-Host "Install-PythonToolCache: Python $Version ($bits) is already registered for this user at $where ($(($products | ForEach-Object { $_.Name }) -join ', ')); uninstalling that first, or the installer would install nothing"
        $un = Start-Process -FilePath $installerPath -ArgumentList @('/uninstall', '/quiet', '/log', "`"$uninstallLog`"") -Wait -PassThru
        Write-Host "Install-PythonToolCache: bundle uninstall exited with code $($un.ExitCode) (log: $uninstallLog)"
        # The bundle's own uninstall can fail on a package that's no longer
        # really there (it did on 2026-09-14), so take out whatever
        # component products it left one at a time.
        foreach ($prod in @((Get-PythonUserRegistration -Version $Version -Arch $Arch).Products)) {
            $msi = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', $prod.ProductCode, '/qn') -Wait -PassThru
            Write-Host "Install-PythonToolCache: msiexec /x $($prod.ProductCode) ($($prod.Name)) exited with code $($msi.ExitCode)"
        }
        $left = @((Get-PythonUserRegistration -Version $Version -Arch $Arch).Products)
        if ($left.Count -gt 0) {
            $manual = ($left | ForEach-Object { "msiexec /x $($_.ProductCode) /qn  # $($_.Name)" }) -join '; '
            throw "Install-PythonToolCache: could not remove the stale Python $Version registration at $where. Still registered: $(($left | ForEach-Object { $_.Name }) -join ', '). Remove them by hand, then rerun: $manual. Uninstall log: $uninstallLog"
        }
    }

    if (Test-Path $versionDir) { Remove-Item -Recurse -Force $versionDir }
    Remove-Item -Force -ErrorAction SilentlyContinue $markerFile
    New-Item -ItemType Directory -Force -Path $versionDir | Out-Null

    Write-Host "Install-PythonToolCache: checksum OK, installing per-user into $versionDir"
    # InstallAllUsers=0 and a custom TargetDir keep this off HKLM and Program
    # Files entirely, so it needs no admin rights -- the whole point, since
    # that's what the automatic setup-python path can't do from this runner.
    # Start-Process joins these with spaces and adds no quotes of its own,
    # so paths are quoted here.
    $proc = Start-Process -FilePath $installerPath -ArgumentList @(
        '/quiet',
        'InstallAllUsers=0',
        'PrependPath=0',
        'Include_launcher=0',
        'Include_test=0',
        "TargetDir=`"$versionDir`"",
        '/log', "`"$installLog`""
    ) -Wait -PassThru
} finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $installerPath
}

$log = Find-InstallerLog -Preferred $installLog -Version $Version -Bits $bits
if ($proc.ExitCode -ne 0) {
    throw "Install-PythonToolCache: python installer exited with code $($proc.ExitCode). Installer log: $log"
}
$present = @()
if ($log) { $present = @(Get-PresentUserPackages -LogPath $log) }
$why = ''
if ($present.Count -gt 0) {
    $why = " The installer found $($present -join ', ') already installed and planned no work for them, so a registration of Python $Version this script didn't detect is pointing somewhere else -- see windows\README.md, 'Language runtimes'."
}
$pythonExe = Join-Path $versionDir 'python.exe'
if (-not (Test-Path $pythonExe)) {
    throw "Install-PythonToolCache: install reported success but $pythonExe is missing.$why Installer log: $log"
}
# python.exe on its own proves little: on 2026-09-15 a reinstall produced
# one with no Lib\, because the standard-library package was still
# registered elsewhere, and `python --version` passed anyway. Import a few
# modules from different packages (Lib, DLLs) before calling it cached.
# 'Continue' for this call only, since under 'Stop' 5.1 turns a native
# command's stderr into a terminating error before $LASTEXITCODE is read.
$ErrorActionPreference = 'Continue'
$importErr = & $pythonExe -c 'import encodings, ssl, sqlite3, venv' 2>&1 | Out-String
$importExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($importExit -ne 0) {
    throw "Install-PythonToolCache: $pythonExe is there but can't import its standard library: $($importErr.Trim()).$why Installer log: $log"
}

New-Item -ItemType File -Force -Path $markerFile | Out-Null
Write-Host "Install-PythonToolCache: done (Python $Version $Arch -> $versionDir)"
