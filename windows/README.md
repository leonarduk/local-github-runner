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

## The pieces

| File | Role |
|---|---|
| `Install-Runner.ps1` | Downloads, SHA256-verifies, and unpacks the runner zip into a slot directory. Run automatically by `Start-RunnerPool.ps1`; call it directly only to pre-stage a slot or bump the version. |
| `runner-loop.ps1` | The actual ephemeral loop: mint a registration token, `config.cmd`, `run.cmd`, deregister, repeat. One process per slot. The Windows analogue of `entrypoint.sh`. |
| `Start-RunnerPool.ps1` | Brings up `-Count` slots for one repo as hidden background processes, logging to `windows\runners\<name>\logs\`. The Windows analogue of `pools.sh up`. |
| `Stop-RunnerPool.ps1` | Signals slots to stop via a stop-file, waits, optionally force-kills. The Windows analogue of `pools.sh down`. |

One level up from this directory:

| File | Role |
|---|---|
| `windows-pools.ps1` | `up` / `down` / `reset` / `list`, mirroring `pools.sh` exactly. |
| `windows-pools.conf` / `.example` | Which repos this host serves natively on Windows, mirroring `pools.conf`. |
| `windows-startRunners.ps1` / `windows-stopRunners.ps1` | Bring the whole fleet in `windows-pools.conf` up or down at once. |

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
