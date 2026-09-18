# Windows (native) runners

The main [README.md](../README.md) covers ephemeral **Linux containers** run
with Docker Compose. This directory is the other half: ephemeral runners for
Windows jobs, run as plain processes on a Windows host instead, because the
Linux image cannot run `windows-latest`-style workflows (MSBuild, .NET
Framework, PowerShell-only cmdlets) and Windows containers are heavy enough
that a native process is the simpler answer for tests you already run on
your own machine.

Same guardrail as the Linux side, unchanged: **[private repositories
only](../README.md#-private-repositories-only)**. A persistent process here
is at least as much attack surface as an ephemeral container, and this path
gets *less* isolation between jobs, not more -- see below.

## What this does not give you

Docker gives the Linux pool a fresh, disposable filesystem per job for free.
There is no equivalent here:

- **The runner's own working files are cleaned per job** (`runner-loop.ps1`
  deletes `_work` before every registration), but anything a job installed
  system-wide -- a chocolatey package, an MSI, a PATH change made outside the
  job's own workspace -- persists into the next job on that slot.
- **A slot killed mid-job is not automatically reaped.** `Stop-RunnerPool.ps1`
  without `-Force` waits for the current job to finish; with `-Force` it kills
  the process outright and the job fails, same as `docker kill` would.
- **No `sudo`-equivalent boundary to reason about**, because there is no
  container: whatever the runner process can do, a job can do, full stop.

If a workflow needs Docker-style per-job isolation on Windows, this is not
that; it is "get `windows-latest`-shaped CI working without paying for GitHub
Actions minutes," matching this repo's actual reason for existing.

## Prerequisites

- **PowerShell 7+ (`pwsh`)** on the host, preferred but not required.
  `Start-RunnerPool.ps1` launches `runner-loop.ps1` via `pwsh` when it is on
  `PATH` and falls back to Windows PowerShell 5.1 (`powershell.exe`) when it is
  not, so a stock Windows install works without installing anything first.
- **An execution policy that will run unsigned local scripts.** Nothing in this
  repo is code-signed, so a host left on `AllSigned` refuses every `.ps1` here
  -- including `windows-startRunners.ps1` and `windows-pools.ps1` -- with
  *"File ... is not digitally signed. You cannot run this script on the current
  system."* That is the policy talking, not a corrupt or untrusted file. See
  [Execution policy](#execution-policy) below.
- **[GitHub CLI](https://cli.github.com)**, authenticated (`gh auth login`) --
  used by `windows-pools.ps1 list` to cross-check what GitHub actually sees,
  same as the Linux side's `pools.sh list`.
- The same `pat.secret` the Linux pools use, at the repo root. One PAT serves
  both fleets.
- **.NET builds hold file locks tenaciously on Windows** -- an antivirus or
  Explorer window into a slot's `_work` directory can make `Reset-Workspace`
  in `runner-loop.ps1` fail to delete it. If a slot's log shows repeated
  registration without ever picking up a job, check for that first.

## Execution policy

Windows blocks unsigned scripts before any of this repo's code gets a say, and
the message names the file rather than the policy, so it reads like the script
is broken:

```
.\startRunners.ps1 : File ...\startRunners.ps1 cannot be loaded. The file
...\startRunners.ps1 is not digitally signed. You cannot run this script on
the current system.
    + FullyQualifiedErrorId : UnauthorizedAccess
```

Check what is actually set -- the answer is a table, not one value. It is
printed in precedence order, so the first non-`Undefined` scope reading *down*
from the top is the one in force:

```powershell
Get-ExecutionPolicy -List
```

`AllSigned` in `LocalMachine` (with `CurrentUser` left `Undefined`, so it
inherits) is the usual culprit. `AllSigned` demands a signature on *every*
script including ones you wrote yourself on this machine, so it blocks the
whole fleet -- `windows-stopRunners.ps1` and `windows-pools.ps1` fail exactly
the same way, which is worth knowing before you conclude one script is at
fault.

Fix it for your account only -- no admin rights, and `LocalMachine` keeps
`AllSigned` for everything else, since `CurrentUser` takes precedence:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

`RemoteSigned` rather than `Bypass` on purpose: a file cloned by git carries no
`Zone.Identifier` alternate data stream, so it counts as local and runs, while
anything genuinely downloaded from the internet still has to be signed. If a
`.ps1` here *does* refuse to run under `RemoteSigned`, it arrived via a browser
or a zip rather than a clone -- confirm with
`Get-Item .\startRunners.ps1 -Stream Zone.Identifier` and clear it with
`Unblock-File`, rather than reaching for `Bypass`.

To run one script without changing any setting -- useful on a machine whose
policy is not yours to change:

```powershell
powershell -ExecutionPolicy Bypass -File .\startRunners.ps1
```

Note that a `Process`-scope policy is per-shell: it explains why a script runs
under one terminal (or under a CI agent, or a tool that spawns
`powershell -ExecutionPolicy Bypass`) and refuses in the window you are typing
in. Compare `Get-ExecutionPolicy -List` in both before assuming the difference
is the script.

## Quick start

```powershell
# From the repo root, in PowerShell 7+:
cp pat.secret pat.secret   # already there if you followed the main README
cp windows-pools.conf.example windows-pools.conf
# edit windows-pools.conf: one line per repo, e.g.
#   jobtrack   leonarduk/jobtrack   2
.\windows-startRunners.ps1
```

Check it actually registered -- a started process is not the same fact as an
online runner, same caveat as the Linux side:

```powershell
.\windows-pools.ps1 list
```

Point a workflow's Windows-flavoured job at it:

```yaml
-    runs-on: windows-latest
+    runs-on: [self-hosted, windows, x64]
```

Tear a pool down:

```powershell
.\windows-stopRunners.ps1          # waits for in-progress jobs to finish
.\windows-stopRunners.ps1 -Force   # kills them instead
```

## Driving pools from something else

`windows-pools.ps1` also has `start` / `stop` / `restart` / `restart-runner`
/ `scale` and `list -Json`, mirroring the Linux side's `pools.sh start` /
`stop` / `restart` / `restart-runner` / `scale` / `list --json` command for
command:

```powershell
.\windows-pools.ps1 start <name>                        # bring one up exactly as windows-pools.conf declares it
.\windows-pools.ps1 stop  <name> [-Force]                # tear one down, unless a runner is busy
.\windows-pools.ps1 restart <name> [-Force]              # stop, then start, unless a runner is busy
.\windows-pools.ps1 restart-runner <container> [-Force]  # restart one runner, unless it is busy
.\windows-pools.ps1 scale <name> <count> [-Force]        # resize one and its count in windows-pools.conf, unless shrinking would stop a busy runner
.\windows-pools.ps1 declare <name> <owner/repo> [count] # add a pool to windows-pools.conf, starting nothing
.\windows-pools.ps1 list -Json [<name>...]                # every pool on this host, and what GitHub actually sees
```

- **`start <name>`** takes nothing but the name. The repo and slot count come
  from that pool's `windows-pools.conf` line, so a caller can't bring up a
  pool that file doesn't describe.
- **`stop <name>`** asks GitHub first and exits `3` instead of stopping if
  any of the pool's slots is busy -- stopping mid-job cancels the job. It
  also exits `3` when GitHub can't be asked, when no runner on GitHub matches
  any of the pool's slots (since "unknown" is not "idle"), or when the pool
  has slots but no repo can be determined for it (no `.repo` file and no
  `windows-pools.conf` line -- there would be nothing to check idle-ness
  against). `-Force` skips the check. Once confirmed idle (or `-Force`), the
  local stop is always forced: an ephemeral runner between jobs just sits
  listening for the next one, so unlike a mid-job process it never exits on
  its own -- see "What this does not give you" above.
- **`restart <name>`** is `stop` then `start`, with the same busy check, so
  it only works on a pool `windows-pools.conf` declares.
- **`restart-runner <container>`** restarts one slot, named as `list -Json`
  reports it in each member's `container` field (`H-<COMPUTERNAME>-jobtrack-slot1`):
  it stops that slot's process and starts it fresh. It refuses if that
  runner is busy, or if GitHub can't be asked. A slot with no runner
  registered -- one stuck failing to register, say -- is restarted, unless
  no slot in its pool matches a runner either, which would mean the matching
  is broken. Searches every pool under `windows\runners\`, declared or not,
  the same way `pools.sh restart-runner` works on any docker container on
  the host.
- **`scale <name> <count>`** resizes a pool `windows-pools.conf` declares.
  Growing starts slots up to `<count>` and never refuses -- nothing running
  is touched. Shrinking stops the slots numbered above `<count>`, highest
  first, and deletes their directories, the way `docker compose up --scale`
  removes containers. It refuses (exit `3`) if one of *those* slots is busy,
  or GitHub can't be asked; `-Force` skips that check. Unlike the Linux
  side, which can't choose which containers compose removes, a busy slot
  the scale keeps doesn't block it. Either way `<count>` is then written
  into the pool's `windows-pools.conf` line, so a later `start` or
  `restart` brings it back at that size rather than undoing the scale.
- **`declare <name> <owner/repo> [count]`** adds a line for a pool
  `windows-pools.conf` doesn't have yet (1 slot unless `[count]` says
  otherwise), so `start`, `restart` and `scale` can bring it up. It starts
  nothing, and refuses a name that's already declared. Names follow
  `pools.sh`'s rules, so one name means the same pool on either side.
- **`list -Json`** prints one JSON array, matching `pools.sh list --json`'s
  shape field for field (`name`, `repo`, `managed`, `desired`, `label`,
  `containers`, `runners`, `members`), with two differences: `label` is
  always `null` (`windows-pools.conf` has no extra-label column), and every
  entry carries `"os":"windows"`. A "container" here is a slot -- a `.pid`
  file under `windows\runners\<name>\slot-N` -- matched to a GitHub runner by
  the deterministic name `Start-RunnerPool.ps1` builds for it
  (`"$HostLabel-$env:COMPUTERNAME-$Name-slot$i"`). `list -Json jobtrack`
  limits it to the named pools, the same reason as the Linux side: every
  pool costs a GitHub API call. GitHub capitalizes the `windows` label on the
  way back (`"Windows"`, not `"windows"` as registered), so every match
  against it is case-insensitive.

`stop`, `restart`, `restart-runner`, a shrinking `scale` and `list -Json`
read `repos/<owner>/<repo>/actions/runners` through the host's own `gh`
login, same as the Linux side -- see the main README's note on the access
that needs. Without it, all but `list -Json` refuse, and `list -Json`
reports `"runners": null`.

### Autoscaling

`.\windows-pools.ps1 autoscale` is the Windows side of `pools.sh autoscale`
(see the main README, "Autoscaling a host's pools"): it resizes the pools
listed in `windows-autoscale.conf` to what is actually queued.

```powershell
Copy-Item windows-autoscale.conf.example windows-autoscale.conf   # gitignored; one "<name> <min> <max> [idle_minutes]" line per pool
.\windows-pools.ps1 autoscale -Once -DryRun                          # what it would do right now, changing nothing
.\windows-pools.ps1 autoscale -Interval 120                          # a pass every 120s until stopped
```

It is its own file, not a column in `autoscale.conf`, for the same reason
`windows-pools.conf` is: `cicaid-pro` can be a Linux pool and a Windows pool
on one host, sized separately. Every pass, for each listed pool:

- **Demand** is the jobs queued in its repo whose `runs-on` labels are all
  among a slot's own -- `self-hosted`, `windows`, `<arch>`, `<HostLabel>`.
  Slots carry no extra labels, so two Windows pools for one repo can't be
  told apart: a job counts against the first one `windows-pools.conf`
  declares. A job asking only for `self-hosted` also fits a Linux pool for
  the same repo, and both fleets' autoscalers will count it.
- **Growing**: to busy slots plus queued jobs, capped at `<max>`, and never
  below `<min>`. It counts running slots, so a slot left stopped is started
  again rather than counted as capacity.
- **Shrinking**: to `<min>` once the pool has had no busy slot and no queued
  job for `[idle_minutes]` (10 by default). It stops the slots numbered above
  `<min>` exactly as `scale` does, after the same busy check, and a refusal
  just leaves the pool for the next pass. The idle clock is kept in
  `.windows-autoscale-state`.
- A pool whose repo GitHub can't be asked about is left as it is, and
  `windows-pools.conf` is never rewritten.

Pass the same `-HostLabel` the pool was started with, if it wasn't the
default `$env:COMPUTERNAME`: it is part of every slot's runner name, and a
mismatch means no slot is ever seen as busy, so no shrink is ever confirmed.
Each pass runs in a child process, so one that fails doesn't end the loop.
It costs the same GitHub API calls as the Linux side -- one per in-flight
run per repo, plus runners -- so raise `-Interval` if several busy repos are
autoscaled. A pool whose repo can't be asked about is logged as "could not
ask GitHub" whatever the cause; `gh api repos/<owner>/<repo>/actions/runs`
by hand shows the real error.
To keep it running, register a Scheduled Task that runs it at logon.

`tests\windows_pools_test.ps1` exercises all of the above against a fake
`gh` and real, harmless, locally-spawned processes standing in for slots --
no Docker daemon to fake here, and nothing real is touched either. Run it
with `pwsh -File tests\windows_pools_test.ps1`, or `powershell.exe -File
tests\windows_pools_test.ps1` where `pwsh` isn't on `PATH`. CI runs both:
`.github\workflows\powershell-tests.yml` runs every `tests\*_test.ps1`
on `windows-latest`, once under Windows PowerShell 5.1 and once under
PowerShell 7, so a new test there is picked up without editing the
workflow.

`Stop-Slot` will not kill a process it cannot tie to the slot that named
it. A `.pid` file outlives the process it names -- a crash, a reboot, a
runner-loop that gave up -- and Windows hands that number to whatever
starts next, so "the PID in the file is running" is not the same claim as
"this slot is running". A slot's process counts as its own only if it
started before the `.pid` file naming it was written, and the handle is
held from that check through to the kill, so `stop`, `scale` and
`autoscale` cannot take down an unrelated process (and, with `taskkill
/T`, its children) because a runner died on this host once.

Two runs of that suite on one machine used to interfere with each other,
by way of the PIDs they recorded for the processes they spawned (issue
#123). The rules that stop them now live in `tests\ProcessTracking.ps1`,
`tests\process_tracking_test.ps1` checks them, and the same workflow's
`Overlapping runs` job runs the suite six times at once, 20s apart, under
both shells -- the shape of an afternoon's work on a real machine, which
one suite per fresh CI VM never is.

## The pieces

| File | Role |
|---|---|
| `Install-Runner.ps1` | Downloads, SHA256-verifies, and unpacks the runner zip into a slot directory. Run automatically by `Start-RunnerPool.ps1`; call it directly only to pre-stage a slot or bump the version. |
| `Install-PythonToolCache.ps1` | Downloads, SHA256-verifies, and per-user-installs one Python version into `windows\toolcache\`, the shared, persistent tool cache every slot's `RUNNER_TOOL_CACHE`/`AGENT_TOOLSDIRECTORY` points at. First removes a stale per-user registration of the same version, which would otherwise make the installer install nothing. Not run automatically -- see "Language runtimes" below. |
| `Install-NodeToolCache.ps1` | Same idea, for Node: downloads, SHA256-verifies (against Node's own published `SHASUMS256.txt`), and unpacks one Node version into the same tool cache. Not run automatically. |
| `runner-loop.ps1` | The actual ephemeral loop: mint a registration token, `config.cmd`, `run.cmd`, deregister, repeat. One process per slot. The Windows analogue of `entrypoint.sh`. |
| `Start-RunnerPool.ps1` | Brings up `-Count` slots for one repo as hidden background processes, logging to `windows\runners\<name>\logs\`. The Windows analogue of `pools.sh up`. |
| `Stop-RunnerPool.ps1` | Signals slots to stop via a stop-file, waits, optionally force-kills. The Windows analogue of `pools.sh down`. |
| `PoolSlot.ps1` | Shared library, dot-sourced by every script above plus `windows-pools.ps1`: per-slot start/stop primitives, `windows-pools.conf` parsing, and GitHub-runner matching. The Windows analogue of `pools.sh`'s internal plumbing functions (`conf_line()`, `repo_runners()`, `require_idle()`, ...). PowerShell 5.1 compatible on purpose -- see its own header. |
| `Restart-RunnerSlot.ps1` | Restarts one slot, identified by the GitHub runner name it registers under. The Windows analogue of `pools.sh restart-runner`, for a single slot. |

One level up from this directory:

| File | Role |
|---|---|
| `windows-pools.ps1` | `up` / `down` / `reset` / `list` / `start` / `stop` / `restart` / `restart-runner` / `scale` / `declare` / `autoscale`, mirroring `pools.sh` exactly. |
| `windows-pools.conf` / `.example` | Which repos this host serves natively on Windows, mirroring `pools.conf`. |
| `windows-autoscale.conf` / `.example` | Which of those pools `autoscale` resizes, and between what bounds, mirroring `autoscale.conf`. |
| `windows-startRunners.ps1` / `windows-stopRunners.ps1` | Bring the whole fleet in `windows-pools.conf` up or down at once. |

## Language runtimes (`actions/setup-python` and friends)

On a **cache miss**, `actions/setup-python` (and `setup-node`, `setup-java`)
tries to download and self-install a runtime, and that self-install assumes
an elevated process: it writes `HKLM\...\Uninstall` entries and runs the
official installer expecting admin rights. `runner-loop.ps1` intentionally
runs unelevated (see "What this does not give you" above), so that install
fails -- job logs show `Requested registry access is not allowed` followed by
the installer exe not being found.

The fix is to make sure it's never a cache miss. `Start-Slot` (in
`PoolSlot.ps1`, behind every path that starts a slot) points
`RUNNER_TOOL_CACHE`/`AGENT_TOOLSDIRECTORY` at `windows\toolcache\`, a
persistent directory outside any slot's ephemeral `_work` (which gets wiped
every job). It sets them in the runner process's environment and also
writes them to the slot's runner `.env`, which the runner reads itself, so a
slot keeps them however it was started. Pre-populate the cache once per
runtime/version a workflow needs:

```powershell
# Python: default version (3.11.9) has a pinned checksum baked in; any other
# version needs -Sha256 explicitly -- see the script's own header for why.
.\windows\Install-PythonToolCache.ps1
.\windows\Install-PythonToolCache.ps1 -Version 3.12.10 -Sha256 67B5635E80EA51072B87941312D00EC8927C4DB9BA18938F7AD2D27B328B95FB

# Node: -Sha256 is always required, copied from that release's own
# https://nodejs.org/dist/<version>/SHASUMS256.txt.
.\windows\Install-NodeToolCache.ps1 -Version v22.23.2 -Sha256 1177B4137BA5ADAA56354AE40F1080C7450E8AE09CECB47DA459D1C52AC99F97
.\windows\Install-NodeToolCache.ps1 -Version v24.20.0 -Sha256 6CAC9FFBCA8F6A47091E4B5C772E0606049C3871CB67D900C0CEDDE630E545BA
```

A workflow asking for `python-version: "3.11"` (or `node-version: "22"`)
matches any cached `3.11.z` (or `22.y.z`) via `actions/setup-python`'s (or
`setup-node`'s) semver range check, so one patch release per minor version
is enough -- it does not need to track the newest patch. `3.12.10` above is
deliberately not the newest `3.12.z`: python.org stops publishing Windows
installers once a branch moves to source-only security releases, so this is
the newest `3.12.z` that still has one.

`windows\toolcache\` is gitignored and disposable like `windows\runners\`,
just longer-lived: rerunning either install script is a no-op once that
version is cached (`-Force` to reinstall).

Versions currently worth caching, from what each repo's workflows actually
pin (`python-version:` / `node-version:` across `.github/workflows/*.yml` in
each repo) -- recheck if a workflow changes its pin:

| Repo | Python | Node |
|---|---|---|
| cicaid-pro | 3.11, 3.12 | -- |
| issue-worm-pro | 3.11, 3.12 | -- |
| jobtrack | 3.11, 3.12 | 22, 24 |

None of jobtrack's or issue-worm-pro's workflows run on `[self-hosted,
windows, x64]` today -- both are Linux-only, even though their pools exist
in `windows-pools.conf`. Caching these ahead of time just means the first
Windows job either repo ever adds won't hit the cache-miss failure
cicaid-pro's did (see the "Language runtimes" intro above); it fixes
nothing currently broken.

### When a job still misses the cache

Check two things, in this order:

1. **Which tool cache the job actually used.** The runner logs it for every
   job:

   ```powershell
   Select-String -Path windows\runners\<pool>\slot-1\_diag\Worker_*.log -Pattern "Well known directory 'Tools'"
   ```

   It should say `windows\toolcache`. `...\slot-N\_work\_tool` means that
   slot's runner started without the setting. Restart it with
   `windows-pools.ps1 restart-runner`, which rewrites the slot's `.env`.
2. **Whether the version is actually cached.**
   `windows\toolcache\Python\<version>\<arch>\python.exe` and the
   `<arch>.complete` file next to that directory must both exist. A
   directory holding only the downloaded installer, or nothing at all, is a
   miss.

### `Install-PythonToolCache.ps1` reports success but installs nothing

The python.org installer is a bundle of per-user MSI packages. It decides
what to do from what Windows Installer says is registered for this user, not
from what is on disk. If this Python version is registered as installed
somewhere else, it plans no work, exits 0, and leaves
`windows\toolcache\Python\<version>\<arch>` empty. Its log
(`%TEMP%\Python 3.11.9 (64-bit)_*.log`) shows
`Detected package: core_JustForMe, state: Present` and `execute: None`.

That happened on 2026-09-15. A cicaid-pro slot restarted with
`restart-runner`, before `Start-Slot` set the tool cache itself, ran its
jobs with `_work\_tool` as the tool cache. On that cache miss `setup-python`
installed 3.11.9 per-user into
`slot-1\_work\_tool\Python\3.11.9\x64`. `runner-loop.ps1` wipes `_work`
before every job, which deleted the files but left the registration:
`HKCU\Software\Python\PythonCore\3.11\InstallPath` still pointed there, and
`py -0p` still listed it. Every later install attempt then did nothing.
`-Force` could cause the same thing on its own: it used to delete the cached
files before running the installer, which then found its own registration
still there.

The script now checks before it installs. Suppose a registration of the
same version points at a directory with no `python.exe`, or at the cache
directory it is about to reinstall. Then the script removes that
registration first: the bundle's own `/uninstall /quiet`, then `msiexec /x`
for any component products still left. If the registration points at a
working Python somewhere else, the script stops and names the path instead
of uninstalling it. Rerun with `-RemoveExisting` to let it uninstall. The script also
won't mark a version cached until its `python.exe` can import the standard
library. On 2026-09-15 one reinstall left a `python.exe` with no `Lib\`, and
`python --version` passed anyway. If the installer exits 0 without producing
a working `python.exe`, the error names the installer log and lists the
`*_JustForMe` packages it found already installed.

To clean up by hand, list every component product still registered, with
the product codes `msiexec` takes, and uninstall **all** of them.
Uninstalling only Core Interpreter and Executables is not enough. On
2026-09-15 that left the standard library registered, and the reinstall
produced a `python.exe` with no `Lib\`:

```powershell
. .\windows\Install-PythonToolCache.ps1   # defines the functions, installs nothing
(Get-PythonUserRegistration -Version 3.11.9 -Arch x64).Products
msiexec /x {B074012B-9B85-4049-BA01-A58A8C4C2236} /qn   # e.g. Python 3.11.9 Core Interpreter (64-bit)
msiexec /x {C038789C-DCB5-42D3-8C51-3BC9DDB26B90} /qn   # e.g. Python 3.11.9 Executables (64-bit)
```

`1605` means that product isn't installed. A `1603` has succeeded on a
second try. Once nothing is listed, rerun `Install-PythonToolCache.ps1`.

If the reinstall itself then fails with `1603` (the log shows an internal MSI
error after `FindRelatedProducts`), leftover per-user installs of other
patch releases of the same minor version (3.11.0 and 3.11.8 here) can be the
cause. The last resort that worked on 2026-09-15: an administrative extract
of each signed component MSI from
`%LOCALAPPDATA%\Package Cache\{guid}v3.11.9150.0\` with
`msiexec /a <msi> TARGETDIR=<toolcache>\Python\3.11.9\x64 /qn`, which
unpacks files without registering anything. Then run
`python -m ensurepip --default-pip`, and write `x64.complete` by hand only
after `python -c "import encodings, ssl, sqlite3, venv"` passes.

## Runtime state

Everything under `windows\runners\` is gitignored and disposable -- delete it
and re-run `Install-Runner.ps1` (or just `windows-startRunners.ps1`) to start
clean. Each pool's directory holds:

```
windows\runners\<name>\
  .repo               # owner/repo this pool serves, read back by `list`
  slot-1\
    ...actions-runner files (config.cmd, run.cmd, bin\, _work\...)
    .pid              # PID of the background runner-loop.ps1 for this slot
    .stop             # dropped by Stop-RunnerPool.ps1; runner-loop.ps1 exits after it
  slot-2\ ...
  logs\
    slot-1.log / .err
```

## Known limits

- **One host, by hand**, same philosophy as the Linux side -- no control
  plane, no service manager wrapping this. If you want the pool to survive a
  reboot, wrap `windows-startRunners.ps1` in a Scheduled Task yourself; that
  is left out deliberately rather than guessed at, since login-vs-system
  context changes what the runner process can see.
- **Weaker isolation than the container pool** -- see "What this does not
  give you" above.
- **`Stop-RunnerPool.ps1` without `-Force` can hang** waiting on a slot with
  no `run.cmd` in progress but a wedged `config.cmd` (e.g. a hung network
  call). Check `logs\slot-N.log` before assuming it is a real job.
