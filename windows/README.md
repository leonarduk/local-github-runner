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

- **PowerShell 7+ (`pwsh`)** on the host. `Start-RunnerPool.ps1` launches
  `runner-loop.ps1` via `pwsh`, not `powershell.exe`.
- **[GitHub CLI](https://cli.github.com)**, authenticated (`gh auth login`) --
  used by `windows-pools.ps1 list` to cross-check what GitHub actually sees,
  same as the Linux side's `pools.sh list`.
- The same `pat.secret` the Linux pools use, at the repo root. One PAT serves
  both fleets.
- **.NET builds hold file locks tenaciously on Windows** -- an antivirus or
  Explorer window into a slot's `_work` directory can make `Reset-Workspace`
  in `runner-loop.ps1` fail to delete it. If a slot's log shows repeated
  registration without ever picking up a job, check for that first.

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

## The pieces

| File | Role |
|---|---|
| `Install-Runner.ps1` | Downloads, SHA256-verifies, and unpacks the runner zip into a slot directory. Run automatically by `Start-RunnerPool.ps1`; call it directly only to pre-stage a slot or bump the version. |
| `Install-PythonToolCache.ps1` | Downloads, SHA256-verifies, and per-user-installs one Python version into `windows\toolcache\`, the shared, persistent tool cache `Start-RunnerPool.ps1` points `RUNNER_TOOL_CACHE`/`AGENT_TOOLSDIRECTORY` at. Not run automatically -- see "Language runtimes" below. |
| `runner-loop.ps1` | The actual ephemeral loop: mint a registration token, `config.cmd`, `run.cmd`, deregister, repeat. One process per slot. The Windows analogue of `entrypoint.sh`. |
| `Start-RunnerPool.ps1` | Brings up `-Count` slots for one repo as hidden background processes, logging to `windows\runners\<name>\logs\`. The Windows analogue of `pools.sh up`. |
| `Stop-RunnerPool.ps1` | Signals slots to stop via a stop-file, waits, optionally force-kills. The Windows analogue of `pools.sh down`. |

One level up from this directory:

| File | Role |
|---|---|
| `windows-pools.ps1` | `up` / `down` / `reset` / `list`, mirroring `pools.sh` exactly. |
| `windows-pools.conf` / `.example` | Which repos this host serves natively on Windows, mirroring `pools.conf`. |
| `windows-startRunners.ps1` / `windows-stopRunners.ps1` | Bring the whole fleet in `windows-pools.conf` up or down at once. |

## Language runtimes (`actions/setup-python` and friends)

On a **cache miss**, `actions/setup-python` (and `setup-node`, `setup-java`)
tries to download and self-install a runtime, and that self-install assumes
an elevated process: it writes `HKLM\...\Uninstall` entries and runs the
official installer expecting admin rights. `runner-loop.ps1` intentionally
runs unelevated (see "What this does not give you" above), so that install
fails -- job logs show `Requested registry access is not allowed` followed by
the installer exe not being found.

The fix is to make sure it's never a cache miss. `Start-RunnerPool.ps1`
points `RUNNER_TOOL_CACHE`/`AGENT_TOOLSDIRECTORY` at `windows\toolcache\`, a
persistent directory outside any slot's ephemeral `_work` (which gets wiped
every job). Pre-populate it once per runtime/version a workflow needs:

```powershell
.\windows\Install-PythonToolCache.ps1                              # Python 3.11.9, x64
.\windows\Install-PythonToolCache.ps1 -Version 3.12.7 -Arch x64
```

A workflow asking for `python-version: "3.11"` matches any cached `3.11.z`
via `actions/setup-python`'s semver range check, so one patch release per
minor version is enough -- it does not need to track the newest patch.
`windows\toolcache\` is gitignored and disposable like `windows\runners\`,
just longer-lived: rerunning the install script is a no-op once a version is
cached (`-Force` to reinstall).

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
