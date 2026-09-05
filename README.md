# local-github-runner

Ephemeral, containerised, self-hosted GitHub Actions runners for private repositories. One checkout runs a pool per repository, on as many machines as you like.

## Why this exists

These repos are private, and their GitHub-hosted Actions minutes are exhausted. Every workflow run failed in a few seconds with no logs, on the default branch as well as on branches. The annotation on the check run says:

> The job was not started because recent account payments have failed or your spending limit needs to be increased.

The jobs never start, so a red CI says nothing about the code. Self-hosted runners do not consume Actions minutes, so this gets the signal back without waiting on a billing change. Sorting the billing out is still the better long-term fix — this is a way to keep working meanwhile.

It began inside one repo, as a fix for that repo's dead CI, and was pointed at four more within a day. It lives here because a tool that serves five repositories should not be a subdirectory of the first one that needed it.

## ⚠️ Private repositories only

**Never point this at a public repository.** On a public repo, anyone can open a pull request, and a workflow triggered by that PR runs *their* code on *your* machine. (GitHub defaults public repos to requiring approval for a first-time contributor, so it is not quite a drive-by -- but that bar is one trivial merged PR high, and it is a setting that can drift.) GitHub's own documentation is unusually blunt about this, and the container boundary here is not a security boundary — jobs get passwordless `sudo` inside the container (see below).

Point it only at repos where you control who can trigger a run. If one is ever made public, tear its pool down first.

The sharpest consequence is the PAT. `entrypoint.sh` needs a token that can mint a
registration token -- a classic PAT with `repo`, which reaches **every repository on
the account** -- and Compose keeps it mounted at `/run/secrets/github_pat` for the
container's whole life, not only during registration. Jobs run with passwordless
`sudo`, so any job can read it. GitHub's fork protections do not cover this: they
withhold *workflow secrets* from fork pull requests and make `GITHUB_TOKEN`
read-only, but this PAT is a file on the runner, not a workflow secret. Prefer a
fine-grained PAT limited to the single target repository, which bounds what a
leaked token can reach.

Two things reduce the blast radius even so:

- **Every container serves exactly one job, then exits** (`--ephemeral`). Nothing a job leaves behind — files, processes, a poisoned pip cache — is visible to the next one.
- **No volumes.** The workspace lives in the container's own writable layer, which is discarded on exit. Adding a named volume for `_work` would quietly undo the isolation.

## Two ways to run it

`Jenkinsfile` drives the whole thing from an existing Jenkins, which is the intended path — see [Managing a pool from Jenkins](#managing-a-pool-from-jenkins). The manual `docker compose` steps below are the same operations by hand, useful for a first run or when debugging.

Either way you need the PAT described next.

## Setup

You need a personal access token that can register runners:

- **Classic PAT** — `repo` scope, or
- **Fine-grained PAT** — the target repositories, `Administration: read & write`

One PAT covering several repositories can serve several pools. The container exchanges it for a short-lived registration token at start-up; the PAT itself is never baked into the image.

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

The host also needs Docker Desktop (or the daemon) set to start on login. `restart: always` brings a pool back after a reboot, but only once the engine is running — otherwise the jobs simply queue with no runner, which looks exactly like the billing failure this exists to work around.

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
4. Bring up whichever pools that machine should serve, as above.

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

## What the image provides

| | |
|---|---|
| Base | `ubuntu:24.04` |
| Runner | `v2.337.0`, SHA256-verified at build, `--disableupdate` |
| Arch | `linux/amd64` and `linux/arm64` (via `TARGETARCH`) |
| Tooling | `git`, `curl`, `jq`, `tar`, `unzip`, `zstd`, `sudo`, `python3` 3.12 |
| JS actions | bundled Node 20 and Node 24, verified working |
| Tool cache | `/opt/hostedtoolcache`, writable — `actions/setup-python` needs this |

Two deliberate choices worth knowing about, because both look like oversights:

- **`sudo` is installed, passwordless.** Workflows install tools with `sudo mv`, matching what a GitHub-hosted runner allows. Removing sudo, or setting `no-new-privileges` in compose, breaks those steps.
- **`RUNNER_MANUALLY_TRAP_SIG=1`.** Makes the runner handle `SIGTERM` itself and finish or cancel the running job cleanly. Without it, `docker stop` mid-job leaves the job hung until GitHub times it out.

## Managing a pool from Jenkins

`Jenkinsfile` is a parameterised pipeline that builds the image and keeps one pool at the requested size. It runs on `agent any`, so it provisions runners on whichever node Jenkins itself runs on.

**One-time setup on the Jenkins instance:**

1. Add a **Secret text** credential with ID **`GITHUB_RUNNER_PAT`**, holding a PAT as described above. Keep it separate from any `GITHUB_TOKEN` credential used for PR comments — this one is strictly more privileged.
2. Create a **Pipeline** job, *Pipeline script from SCM*, pointing at this repo with **Script Path** `Jenkinsfile`.

The Jenkins node needs the Docker CLI and a reachable Docker socket. `allotmint-jenkins:latest` already has both (`docker` plus Compose v5).

**One job per pool.** The compose project name is derived from `GITHUB_REPOSITORY`, so a second job pointed at a second repository manages a separate set of containers rather than fighting over the first job's.

**Parameters:**

| | |
|---|---|
| `ACTION` | `up` (default, idempotent), `status`, `restart`, `down` |
| `RUNNER_COUNT` | Pool size. Size it to the jobs that can run at once, or they queue |
| `RUNNER_HOST_LABEL` | Names the machine, e.g. `bedroom` |
| `GITHUB_REPOSITORY` | Which repo the runners serve. Required; also names the pool |
| `REBUILD_IMAGE` | `--no-cache --pull`; needed after bumping `RUNNER_VERSION` |

`ACTION=up` converges the pool without disturbing a container mid-job, so re-running it is always safe. The **Verify** stage polls the GitHub API until the requested number of runners are online with the right label, and fails the build with the container logs attached if they never arrive.

Two implementation notes, because both look odd until you hit them:

- **The PAT is written under `/var/lib/jenkins/gh-runner/<pool>/`, outside the workspace.** Compose bind-mounts that file and re-reads it on every container restart — and these containers restart constantly, one per job. A PAT written into the workspace works right up until Jenkins cleans it, then fails in a way that looks nothing like the cause.
- **The Verify stage parses JSON using `jq` from inside the runner image** (`docker run --entrypoint jq`). The Jenkins image has `curl` and `git` but neither `jq` nor `python3`, and borrowing the runner image's own `jq` avoids adding a dependency to the node or assuming a pipeline plugin.

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
- **`mem_limit: 2g` / `pids_limit: 512`** are conservative. If a build is OOM-killed, raise them rather than removing them.
- **Linux only.** A workflow pinned to `windows-*` or `macos-*` will never match these runners.
- **Pool names use the repo name, not `owner/repo`.** Two repos of the same name under different owners would collide.
