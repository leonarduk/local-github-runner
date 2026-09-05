# Self-hosted GitHub Actions runner

An ephemeral, containerised Actions runner for this repository.

## Why this exists

This repo is private, and its GitHub-hosted Actions minutes are exhausted. Every workflow run since the repo's first commit has failed in a few seconds with no logs, on `master` as well as on branches. The annotation on the check run says:

> The job was not started because recent account payments have failed or your spending limit needs to be increased.

The jobs never start, so a red CI here says nothing about the code. Self-hosted runners do not consume Actions minutes, so this gets the signal back without waiting on a billing change. Sorting the billing out is still the better long-term fix — this is a way to keep working meanwhile.

## ⚠️ Private repositories only

**Never point this at a public repository.** On a public repo, anyone can open a pull request, and a workflow triggered by that PR runs *their* code on *your* machine. GitHub's own documentation is unusually blunt about this, and the container boundary here is not a security boundary — jobs get passwordless `sudo` inside the container (see below).

This repo is private, so only people you have granted access can trigger a run. If it is ever made public, tear these runners down first.

Two things reduce the blast radius even so:

- **Every container serves exactly one job, then exits** (`--ephemeral`). Nothing a job leaves behind — files, processes, a poisoned pip cache — is visible to the next one.
- **No volumes.** The workspace lives in the container's own writable layer, which is discarded on exit. Adding a named volume for `_work` would quietly undo the isolation.

## Two ways to run it

`runner/Jenkinsfile` drives the whole thing from your existing Jenkins, which is the intended path — see [Managing the pool from Jenkins](#managing-the-pool-from-jenkins). The manual `docker compose` steps below are the same operations by hand, useful for a first run or when debugging.

Either way you need the PAT described next.

## Setup

You need a personal access token that can register runners:

- **Classic PAT** — `repo` scope, or
- **Fine-grained PAT** — this repository, `Administration: read & write`

The container exchanges it for a short-lived registration token at start-up. The PAT itself is never baked into the image.

```bash
cd runner
printf '%s' 'ghp_your_token_here' > pat.secret   # gitignored
docker compose up -d --build
docker compose logs -f
```

A healthy start looks like:

```
runner-entrypoint: requesting a registration token for leonarduk/spring-professional-udemy-practice-tests
runner-entrypoint: configuring 4f2c1a9b3e77-1
runner-entrypoint: waiting for a job
```

The runner then appears under **Settings → Actions → Runners** as idle. Scale the pool with `docker compose up -d --scale runner=3`.

## Point the workflow at it

The runner will sit idle until a job asks for it. In `.github/workflows/ci.yml`:

```yaml
-    runs-on: ubuntu-latest
+    runs-on: [self-hosted, linux, x64]
```

**This change is not applied here.** PR #9 also edits `ci.yml`, and making the same file a conflict in two open PRs is not worth it — apply it once the merge order is settled. Both jobs (`validate` and `lint-workflows`) need it, or the untouched one keeps failing to start for the original reason.

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

- **`sudo` is installed, passwordless.** This repo's `ci.yml` installs `actionlint` with `sudo mv`, matching what a GitHub-hosted runner allows. Removing sudo, or setting `no-new-privileges` in compose, breaks that step.
- **`RUNNER_MANUALLY_TRAP_SIG=1`.** Makes the runner handle `SIGTERM` itself and finish or cancel the running job cleanly. Without it, `docker stop` mid-job leaves the job hung until GitHub times it out.

## Managing the pool from Jenkins

`runner/Jenkinsfile` is a parameterised pipeline that builds the image and keeps the pool at the requested size. It runs on `agent any`, so it provisions runners on whichever node Jenkins itself runs on.

**One-time setup on the Jenkins instance:**

1. Add a **Secret text** credential with ID **`GITHUB_RUNNER_PAT`**, holding a PAT as described above. Keep it separate from the `GITHUB_TOKEN` credential the allotmint pipelines use for PR comments — this one is strictly more privileged.
2. Create a **Pipeline** job, *Pipeline script from SCM*, pointing at this repo with **Script Path** `runner/Jenkinsfile`.

The Jenkins node needs the Docker CLI and a reachable Docker socket. `allotmint-jenkins:latest` already has both (`docker` plus Compose v5).

**Parameters:**

| | |
|---|---|
| `ACTION` | `up` (default, idempotent), `status`, `restart`, `down` |
| `RUNNER_COUNT` | Pool size. `2` keeps the two `ci.yml` jobs from queueing behind each other |
| `RUNNER_HOST_LABEL` | Names the machine, e.g. `bedroom` |
| `GITHUB_REPOSITORY` | Which repo the runners serve |
| `REBUILD_IMAGE` | `--no-cache --pull`; needed after bumping `RUNNER_VERSION` |

`ACTION=up` converges the pool without disturbing a container mid-job, so re-running it is always safe. The **Verify** stage polls the GitHub API until the requested number of runners are online with the right label, and fails the build with the container logs attached if they never arrive.

Two implementation notes, because both look odd until you hit them:

- **The PAT is written to `/var/lib/jenkins/gh-runner/pat.secret`, outside the workspace.** Compose bind-mounts that file and re-reads it on every container restart — and these containers restart constantly, one per job. A PAT written into the workspace works right up until Jenkins cleans it, then fails in a way that looks nothing like the cause.
- **The Verify stage parses JSON using `jq` from inside the runner image** (`docker run --entrypoint jq`). This Jenkins image has `curl` and `git` but neither `jq` nor `python3`, and borrowing the runner image's own `jq` avoids adding a dependency to the node or assuming a pipeline plugin.

## Maintenance

Bumping the runner version means editing `RUNNER_VERSION` **and** the two checksums in the `Dockerfile` together — they are per-version, and a mismatched pair fails the build rather than silently skipping verification. The SHAs are published in each release's notes at <https://github.com/actions/runner/releases>.

`--disableupdate` keeps the pinned version honest. If GitHub starts refusing jobs from a version this old, drop that flag and rebuild the image to match.

## Teardown

```bash
docker compose down
```

Each container deregisters itself on the way out, so nothing should be left behind. If a container was killed rather than stopped — `docker kill`, a host crash — its runner lingers as "offline" under Settings → Actions → Runners and needs removing by hand there.

## Known limits

- **No Docker-in-Docker.** No job here needs it. Adding it means mounting the host's Docker socket, which hands any job root on the host — do not do that on the strength of this README alone.
- **`actions/cache` has no backing store**, so cache steps are no-ops that cost a little time. Fine for this repo; worth knowing if a workflow starts depending on a warm cache.
- **`mem_limit: 2g` / `pids_limit: 512`** are conservative. If a build is OOM-killed, raise them rather than removing them.
- The container is `linux/amd64` on this host. A workflow pinned to `windows-*` or `macos-*` will never match it.
