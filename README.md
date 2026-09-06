# local-github-runner

Ephemeral, containerised, self-hosted GitHub Actions runners for private repositories. One checkout runs a pool per repository, on as many machines as you like.

**[Quick start](#quick-start)** -- if you just want it running, start there.

<details>
<summary>Everything else in this file</summary>

- [Why this exists](#why-this-exists)
- [What this is not](#what-this-is-not)
- [Private repositories only](#-private-repositories-only)
- [How it is run](#how-it-is-run)
- [Host prerequisites](#host-prerequisites)
- [Setup](#setup)
- [Several repos from one checkout](#several-repos-from-one-checkout)
- [Several machines](#several-machines)
- [Point a workflow at it](#point-a-workflow-at-it)
- [What the image provides](#what-the-image-provides)
- [Maintenance](#maintenance)
- [Teardown](#teardown)
- [Known limits](#known-limits)
- [Further reading](#further-reading)

</details>

## Quick start

**Have these three ready before starting:**
- [Docker Desktop](https://docs.docker.com/get-started/introduction/get-docker-desktop/) (or [Docker Engine](https://docs.docker.com/engine/install/) on Linux), set to start on login
- [GitHub CLI](https://cli.github.com), authenticated -- `gh auth login`
- A GitHub personal access token (PAT) -- create one at [github.com/settings/tokens/new](https://github.com/settings/tokens/new): give it a name, tick the **`repo`** scope checkbox, click **Generate token**, and copy the value it shows you. GitHub only displays it this once.

**Windows:** run every command below through Git Bash, not raw PowerShell, and not
bare `bash` -- see [Host prerequisites](#host-prerequisites) if a command below says
`gh: command not found` even though `gh` works fine elsewhere. That single gotcha costs
more time than everything else in this file combined.

**1. Clone it:**
```bash
git clone https://github.com/leonarduk/local-github-runner
cd local-github-runner
```

**2. Save the PAT from above -- gitignored, never committed:**

```bash
# macOS / Linux / Git Bash
printf '%s' 'ghp_your_token_here' > pat.secret
```
```powershell
# Windows PowerShell
[System.IO.File]::WriteAllText("$PWD\pat.secret", 'ghp_your_token_here')
```

**3. Name this machine:**
```bash
cp .env.example .env
# then edit .env and set RUNNER_HOST_LABEL to something like "bedroom" or "office-desktop"
```

**4. List the repo(s) this machine should serve, and bring them up:**
```bash
cp pools.conf.example pools.conf
# edit pools.conf -- replace its example lines with your own, one per repo:
#   jobtrack   owner/jobtrack   2
# "owner" is your GitHub username or org, not a literal word -- for the
# author that's "leonarduk", e.g. leonarduk/jobtrack; use your own instead.
./startRunners.sh
```

**5. Confirm it actually registered** -- a started container is not the same fact as an online runner:
```bash
./pools.sh list
```

Done. Now [point a workflow at it](#point-a-workflow-at-it).

Adding a repo later means adding a line to `pools.conf` and running
`./startRunners.sh` again. `./pools.sh up <name> <owner/repo> [count]` is the
one-off primitive underneath it, for a single pool with no config file at all.
Setting up a second machine, or want repos to opt themselves in instead of
being listed here by hand? See [Several machines](#several-machines).

## Why this exists

These repos are private, and their GitHub-hosted Actions minutes are exhausted. Every workflow run failed in a few seconds with no logs, on the default branch as well as on branches. The annotation on the check run says:

> The job was not started because recent account payments have failed or your spending limit needs to be increased.

The jobs never start, so a red CI says nothing about the code. Self-hosted runners do not consume Actions minutes, so this gets the signal back without waiting on a billing change. Sorting the billing out is still the better long-term fix — this is a way to keep working meanwhile.

It began inside one repo, as a fix for that repo's dead CI, and was pointed at four more within a day. It lives here because a tool that serves five repositories should not be a subdirectory of the first one that needed it.

## What this is not

A single-host tool, deliberately. It is a Dockerfile and a compose file that
keep a handful of ephemeral runners alive on one machine, and the interesting
part is not the container -- it is the collection of failure modes documented
here, most of which cost somebody an afternoon to find.

If you need something else, use something else:

- **Kubernetes, autoscaling, or more than one team** ->
  [actions-runner-controller](https://github.com/actions/actions-runner-controller),
  which is the supported answer and does all of that properly.
- **A public repository** -> nothing here, and see the next section. This is
  not a limitation to work around; it is the one hard rule.
- **Windows or macOS jobs** -> these runners are Linux containers only.
- **Jobs needing `container:`, `services:`, or Docker-based actions** -> those
  need Docker-in-Docker, which this deliberately does not provide.

## ⚠️ Private repositories only

**Never point this at a public repository.** On a public repo, anyone can open a pull request, and a workflow triggered by that PR runs *their* code on *your* machine. (GitHub defaults public repos to requiring approval for a first-time contributor, so it is not quite a drive-by -- but that bar is one trivial merged PR high, and it is a setting that can drift.) [GitHub's own documentation](https://docs.github.com/en/actions/reference/security/secure-use)
is unusually blunt about this: "Self-hosted runners should almost never be used
for public repositories on GitHub, because any user can open pull requests
against the repository and compromise the environment." The container boundary
here is not a security boundary either — jobs get passwordless `sudo` inside the
container (see below).

Point it only at repos where you control who can trigger a run. If one is ever made public, tear its pool down first.

The sharpest consequence is the PAT. `entrypoint.sh` needs a token that can mint a
registration token -- a classic PAT with `repo`, which reaches **every repository on
the account** -- and Compose keeps it mounted at `/run/secrets/github_pat` for the
container's whole life, not only during registration. Jobs run with passwordless
`sudo`, so any job can read it. GitHub's fork protections do not cover this: they
withhold *workflow secrets* from fork pull requests and make `GITHUB_TOKEN`
read-only, but this PAT is a file on the runner, not a workflow secret. Prefer a
[fine-grained PAT](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
limited to the single target repository, which bounds what a
leaked token can reach.

Two things reduce the blast radius even so:

- **Every container serves exactly one job, then exits** (`--ephemeral`). Nothing a job leaves behind — files, processes, a poisoned pip cache — is visible to the next one.
- **No volumes.** The workspace lives in the container's own writable layer, which is discarded on exit. Adding a named volume for `_work` would quietly undo the isolation.

## How it is run

By hand, per machine, with `docker compose`. There is no control plane and
nothing to install besides Docker: a host that should serve runners gets a
clone, a PAT, and one `compose up` per pool. A machine that should stop serving
them gets a `compose down`.

This repo did carry a Jenkins pipeline to do the same thing. It was removed:
for a single host it wrapped two environment variables and a `compose up` while
adding a stateful service holding the Docker socket -- root on the host -- and
it was never actually run end to end. Per-machine setup is cheap enough that
the orchestration was not buying anything.

`pools.sh` wraps the operations below for a host running several pools:

```bash
./pools.sh up    <name> <owner/repo> [count]   # bring a pool up
./pools.sh down  <name>                        # tear one down
./pools.sh reset <name> <owner/repo> [count]    # down, then up fresh
./pools.sh list                                 # every pool on this host, and what GitHub actually sees
```

`<name>` is just the label in the project name (`gh-runner-<name>`); it need
not match the repo. `list` is the one worth knowing about even if you never
use the others: it cross-checks each pool's containers against GitHub's own
`actions/runners` API, which is the only way to catch a pool that looks fine
in `docker ps` but registered nothing.

You need the PAT described next.

## Host prerequisites

Checklist first, story below for whichever line actually bites:

- [ ] **Docker** installed, engine set to start on login
- [ ] Enough memory allocated in Docker Desktop for however many containers you run
- [ ] **Sleep disabled** on this host while it serves runners (both idle timeout and lid-close --
  see below, this one is sneaky)
- [ ] **GitHub CLI** installed and authenticated
- [ ] On Windows, scripts are invoked via Git Bash, not raw `bash` (which may silently be WSL)

The pool is only as reliable as the machine under it, and two of these are the
kind of thing you debug for an afternoon before suspecting them.

**Docker.** Docker Desktop on Windows or macOS, Docker Engine on Linux. On
Windows use the WSL2 backend; the Hyper-V backend works but is slower at the
bind mounts this uses.

Set the engine to **start on login** — Docker Desktop → *Settings* → *General* →
*Start Docker Desktop when you sign in*. `restart: always` brings a pool back
after a reboot, but only once the engine is running. Without it the jobs simply
queue with no runner, which looks exactly like the billing failure this exists
to work around.

Give it enough memory. Each runner declares `mem_limit: 1g`, so *N* runners
across all your pools can ask for *N* GiB, against whatever ceiling Docker
Desktop is set to in *Settings* → *Resources*. Over-committing does not error —
it shows up as jobs mysteriously crawling when several repos build at once.
Count the containers, not the pools.

**Sleep. This one silently cancels jobs.** A host that suspends mid-job stops
the runner's heartbeat, and GitHub cancels the job server-side. The signature is
unmistakable once you know it, and it shows up two different ways depending on
whether a job had been claimed yet when the host went under.

**A job already running** dies about ten minutes after the host goes under —
that interval is GitHub's own patience with a runner that has stopped
answering, not any timeout on your machine, so it is the same ten minutes
whatever sent the host to sleep. Do not read it as pointing at a ten-minute
power setting; that coincidence cost us an afternoon here. The tell is
that its logs keep going *past its own recorded completion*: the container had
the step suspended, not finished, and uploads the rest on wake into a job record
that is already closed. One observed here completed at `13:42:49Z` with log
lines running to `14:47:09Z` — 64 minutes after it supposedly ended. A job that
finished before its own logs were written is not a race condition; it is a
sleeping host, and it is a cheap thing to grep for.

**A job still queued** simply is not claimed, because no runner is awake to take
it. It then starts at the moment of wake and runs at completely normal speed —
in the same incident, a run queued at `13:32:45Z` started its jobs at
`14:47:26Z` and finished them in 8 to 109 seconds, all green. Nothing was slow;
the machine was absent. This one is easy to misread as contention, which is what
makes the wake timestamp worth checking: jobs across *different repositories*
resuming within the same few seconds is one host waking, not several flakes.

Either way it is intermittent — jobs shorter than the outage finish fine — so
it reads as a flaky test suite rather than a host problem.

There are two separate ways a host goes under, and fixing one does nothing
about the other. On Windows both are recorded: Kernel-Power event 42 carries a
reason, where **7 is an idle timeout** and **0 is the lid or the power button**.
Check which you actually have before fixing anything.

```powershell
# Which kind of sleep, and when -- reason 7 = idle, reason 0 = lid/button
Get-WinEvent -FilterHashtable @{LogName='System';
  ProviderName='Microsoft-Windows-Kernel-Power'; Id=42} |
  ForEach-Object { '{0:u} reason={1}' -f $_.TimeCreated, $_.Properties[2].Value }

# Idle timeout: STANDBYIDLE's AC index, in seconds
powercfg /query SCHEME_CURRENT SUB_SLEEP
powercfg /change standby-timeout-ac 0
```

Closing the lid is the one that catches people, because a laptop on a desk gets
shut without anyone thinking of it as powering the machine down, and no idle
timeout protects against it. Worse, the setting that governs it is hidden from
the Power Options UI on some machines, so it cannot be found by clicking
through Windows settings — it has to be set by GUID, elevated:

```powershell
# Lid close -> do nothing, on AC. SUB_BUTTONS / LIDACTION.
powercfg /setacvalueindex SCHEME_CURRENT `
  4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
powercfg /setactive SCHEME_CURRENT
```

That binds to the **active power scheme only**, so switching schemes silently
reverts it. And a closed lid under sustained build load is a real thermal
question on a laptop — pair it with the machine being docked and ventilated
rather than setting it blind.

```bash
# macOS
sudo pmset -c sleep 0
# Linux -- or set logind's IdleAction to ignore
systemd-inhibit --what=idle:sleep --who=gh-runner --why=CI sleep infinity &
```

Disabling sleep on battery too is usually the wrong trade on a laptop; if the
machine is a CI host on AC, `standby-timeout-ac 0` is enough. Display sleep is
harmless — it is system standby that kills jobs.

Registering a runner by hand, without any of the tooling in this repo, is
[documented directly by GitHub](https://docs.github.com/actions/hosting-your-own-runners/adding-self-hosted-runners)
— *Settings -> Actions -> Runners -> New self-hosted runner* on the target repo.
Everything below is the same registration, done by `entrypoint.sh` inside a
disposable container instead of by hand on a long-lived machine.

**GitHub CLI.** pools.sh, startRunners.sh/stopRunners.sh and discoverPools.sh
all shell out to gh on the host to list repos and check which runners are
actually online -- a separate installation from the gh baked into the runner
container, which only helps workflows running inside a job. Install it and
authenticate before using any of these scripts:

```powershell
winget install --id GitHub.cli   # Windows; see https://cli.github.com for other platforms
gh auth login                    # in a new shell, so PATH picks up the install
```

On Windows, invoke every script here with an explicit path to Git Bash rather
than bare `bash` -- if WSL is installed (likely, since Docker Desktop's
recommended backend needs it), `bash` on PATH resolves to
`C:\WINDOWS\system32\bash.exe`, WSL's launcher into a separate Linux
environment with its own PATH. gh installed on Windows via winget is
invisible there, so a script fails with a plain `gh: command not found` that
has nothing to do with whether gh is actually installed. Confirm which one
`bash` means with `Get-Command bash`, and if it points into
`system32` or `WindowsApps`, use the real path instead:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' ./discoverPools.sh leonarduk
```

Without it, these scripts fail fast with `gh: command not found` rather than
silently doing nothing -- but on Windows that error can end up wherever
stderr goes for whatever launched bash, so it is easy to miss if you are not
looking for it.

## Setup

You need a personal access token that can register runners:

- **Classic PAT** — `repo` scope, or
- **Fine-grained PAT** — the target repositories, `Administration: read & write`

One PAT covering several repositories can serve several pools. The container exchanges it for a short-lived registration token at start-up; the PAT itself is never baked into the image.

[Quick start](#quick-start) already walked through this via `pools.sh` -- what follows is the same thing one level down, with the raw `docker compose` command `pools.sh up` runs for you, for when something needs debugging directly.

```bash
git clone https://github.com/leonarduk/local-github-runner
cd local-github-runner
printf '%s' 'ghp_your_token_here' > pat.secret   # gitignored
cp .env.example .env                             # set RUNNER_HOST_LABEL
GITHUB_REPOSITORY=owner/repo docker compose up -d --build
docker compose logs -f
```

A healthy start looks like:

```
runner-entrypoint: requesting a registration token for owner/repo
runner-entrypoint: configuring bedroom-4f2c1a9b3e77-1
runner-entrypoint: waiting for a job
```

The runner then appears under the repo's **Settings → Actions → Runners** as idle. `compose.yaml` declares two of them; override that for a one-off with `--scale runner=3`.

`GITHUB_REPOSITORY` has no default and the `up` fails without it. That is deliberate: it used to default to the one repo this was written for, which is exactly the kind of thing that survives a copy to a new machine and quietly registers runners against the wrong repository.

### Check the pool is really up

`docker compose up` returning 0 means the containers started, not that any
runner registered. Registration happens later, inside the container, and can
fail on its own -- a PAT without the right scope, a typo in
`GITHUB_REPOSITORY`, a repo the token cannot see -- leaving containers that
restart forever while GitHub shows nothing. Ask GitHub rather than Docker:

```bash
gh api repos/OWNER/REPO/actions/runners \
  --jq '.runners[] | "\(.name)  \(.status)  busy=\(.busy)"'
```

Expect one `online` line per container, each prefixed with the host label from
`.env`. Fewer than you scaled to means some are still registering or some are
failing; `docker compose logs -f` says which. Runners listed `offline` with no
container behind them are strays from a container that was killed rather than
stopped -- clear them with
`gh api -X DELETE repos/OWNER/REPO/actions/runners/ID`.

## Several repos from one checkout

The compose **project name** is the only thing separating one pool from another. Two pools sharing it are the same pool — an `up` for the second repo silently reconfigures the first repo's containers rather than adding to them. So set it alongside the repository:

```bash
GITHUB_REPOSITORY=leonarduk/jobtrack COMPOSE_PROJECT_NAME=gh-runner-jobtrack docker compose up -d
```

Only put per-machine facts in `.env` — `RUNNER_HOST_LABEL`, and `GITHUB_REPOSITORY` if this host serves exactly one repo. Every pool started from this directory reads that same file, so anything that differs per pool belongs on the command line.

Check what is running, across all pools, with `docker ps --filter name=gh-runner`.

## Several machines

Nothing is host-specific except two gitignored files, so a second machine is a clone plus those:

1. `git clone` this repo.
2. Write the PAT to `pat.secret` — it never travels through git.
3. `cp .env.example .env` and set `RUNNER_HOST_LABEL` to that machine's name, e.g. `bedroom`.
4. Bring up whichever pools that machine should serve. Two ways:
   - `cp pools.conf.example pools.conf`, edit it to list the repos this host serves, then `./startRunners.sh`.
   - Or `./discoverPools.sh <owner>`, which needs no local config at all -- it finds every private repo
     under `<owner>` carrying a `.local_runner` marker file and brings each one up.
   Either way, `./pools.sh up <name> <owner/repo> [count]` remains the one-off, no-config primitive underneath both.

`RUNNER_HOST_LABEL` becomes both a runner label and the runner-name prefix, so the GitHub runner list and `gh api .../actions/runners` say which box a runner is on — container hostnames are random hex and no help. It also lets a workflow pin a job to one machine with `runs-on: [self-hosted, bedroom]`.

Runners on different machines serving the same repo simply join the same pool: GitHub hands each queued job to whichever is free. There is no coordination between hosts and none is needed.

The image is built per machine (`--build`). There is no registry involved, so a second host costs one ~1.4GB build rather than any shared infrastructure.

## Point a workflow at it

A runner sits idle until a job asks for it. In the target repo's workflow:

```yaml
-    runs-on: ubuntu-latest
+    runs-on: [self-hosted, linux, x64]
```

Every job in the workflow needs the label, or the untouched ones keep failing to start for the original reason. Keep the `ubuntu-latest` line commented directly above each replacement, so going back once billing is sorted is a one-line edit at the point of use rather than an archaeology exercise.

Verified end to end on 2026-09-05 against `leonarduk/spring-professional-udemy-practice-tests`: both its jobs ran on a pool from this image and passed, in 7s and 32s, having previously failed in about 2s without starting.

GitHub's own reference for this syntax and the default label set is
[Choosing the runner for a job](https://docs.github.com/actions/using-jobs/choosing-the-runner-for-a-job).

## What the image provides

| | |
|---|---|
| Base | `ubuntu:24.04` |
| Runner | `v2.337.0`, SHA256-verified at build, `--disableupdate` |
| Arch | `linux/amd64` and `linux/arm64` (via `TARGETARCH`) |
| Tooling | `git`, `curl`, `jq`, `tar`, `unzip`, `zstd`, `sudo`, `python3` 3.12, `uuidgen`, `pkill` |
| `gh` | `v2.100.0`, SHA256-verified at build — preinstalled on GitHub-hosted images, so workflows assume it |
| JS actions | bundled Node 20 and Node 24, verified working |
| Tool cache | `/opt/hostedtoolcache`, writable — `actions/setup-python` needs this |

Two deliberate choices worth knowing about, because both look like oversights:

- **`sudo` is installed, passwordless.** Workflows install tools with `sudo mv`, matching what a GitHub-hosted runner allows. Removing sudo, or setting `no-new-privileges` in compose, breaks those steps.
- **`gh` is baked in rather than installed per job.** Ubuntu's own package is
  too old for the `--json` flags workflows use, so repos had started curling
  the release tarball at job time without verifying it. Installing it here,
  checksummed, removes that. Workflows that guard on `gh` already being on
  `PATH` become no-ops; the binary carries no credentials, so each workflow
  still supplies its own `GH_TOKEN`.
- **`RUNNER_MANUALLY_TRAP_SIG=1`.** Makes the runner handle `SIGTERM` itself and finish or cancel the running job cleanly. Without it, `docker stop` mid-job leaves the job hung until GitHub times it out.

## Maintenance

Bumping the runner version means editing `RUNNER_VERSION` **and** the two checksums in the `Dockerfile` together — they are per-version, and a mismatched pair fails the build rather than silently skipping verification. The SHAs are published in each release's notes at <https://github.com/actions/runner/releases>.

`--disableupdate` keeps the pinned version honest. If GitHub starts refusing jobs from a version this old, drop that flag and rebuild the image to match.

A version bump has to reach every machine, since each builds its own image. Nothing enforces that; `docker images local-github-runner:local` on each host is how you tell.

## Teardown

```bash
COMPOSE_PROJECT_NAME=gh-runner-repo docker compose down
```

Each container deregisters itself on the way out, so nothing should be left behind — a `down` of a two-runner pool completes in about five seconds with both registrations gone.

That relies on `entrypoint.sh` signalling `Runner.Listener` directly rather than only `run.sh`: a signal to the wrapper alone never reaches the process `RUNNER_MANUALLY_TRAP_SIG=1` arms, and the container is then SIGKILLed with `deregister()` unreached. If a container is killed outright anyway — `docker kill`, a host crash — its runner lingers as "offline" under Settings → Actions → Runners and needs removing there, or with `gh api -X DELETE repos/OWNER/REPO/actions/runners/ID`. The container itself recovers unaided: the leftover `.runner` from its previous life is cleared at start-up before it reconfigures.

## Known limits

- **No Docker-in-Docker.** Adding it means mounting the host's Docker socket, which hands any job root on the host — do not do that on the strength of this README alone.
- **`actions/cache` has no backing store**, so cache steps are no-ops that cost a little time. Worth knowing if a workflow starts depending on a warm cache.
- **`pip install` only works after `actions/setup-python`.** The base is Ubuntu 24.04, whose system interpreter refuses installs under PEP 668 (`externally-managed-environment`). `setup-python` puts its own interpreter on PATH first — but a workflow that drops that step keeps working on a GitHub-hosted runner and fails here.
- **`mem_limit: 1g` / `pids_limit: 512`** are conservative. If a build is OOM-killed, raise them rather than removing them.
- **Linux only.** A workflow pinned to `windows-*` or `macos-*` will never match these runners.
- **Pool names use the repo name, not `owner/repo`.** Two repos of the same name under different owners would collide.

## Further reading

Everything above is GitHub's own supported mechanism -- a self-hosted runner
registered the normal way -- wrapped in a container and a compose file for
convenience. None of it depends on this repo; every piece is documented
independently, and it is worth reading the source rather than taking this
README's word for the security-critical parts:

- [About self-hosted runners](https://docs.github.com/actions/hosting-your-own-runners) — what one is, and the three levels (repository, organization, enterprise).
- [Adding self-hosted runners](https://docs.github.com/actions/hosting-your-own-runners/adding-self-hosted-runners) — the manual registration flow `entrypoint.sh` automates.
- [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use) — the authoritative source for the public-repository warning above. Read this one regardless of whether you read anything else here.
- [Choosing the runner for a job](https://docs.github.com/actions/using-jobs/choosing-the-runner-for-a-job) — `runs-on:` syntax and how label matching works.
- [Managing your personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) — classic vs. fine-grained, and how to scope the one this needs.
- [actions-runner-controller](https://github.com/actions/actions-runner-controller) — GitHub's own answer once one host and a compose file stop being enough.
