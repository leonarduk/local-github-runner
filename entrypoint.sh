#!/usr/bin/env bash
#
# Register an ephemeral self-hosted runner, run exactly one job, deregister.
#
# A registration token is short-lived (one hour) and single-use, so it cannot
# be baked into the image -- one is minted here at container start from a PAT.
# The PAT is read from a file when RUNNER_TOKEN_FILE is set, so it can be a
# Docker secret rather than an environment variable visible to `docker
# inspect` and to every process in the container.

set -euo pipefail

fail() { echo "runner-entrypoint: $*" >&2; exit 1; }
log()  { echo "runner-entrypoint: $*"; }

: "${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY to owner/repo}"

# Accept the PAT from a file (preferred) or an env var (convenient).
if [[ -n "${RUNNER_TOKEN_FILE:-}" ]]; then
    [[ -r "${RUNNER_TOKEN_FILE}" ]] || fail "RUNNER_TOKEN_FILE is not readable: ${RUNNER_TOKEN_FILE}"
    GITHUB_PAT="$(< "${RUNNER_TOKEN_FILE}")"
fi
: "${GITHUB_PAT:?set GITHUB_PAT or RUNNER_TOKEN_FILE}"

GITHUB_URL="${GITHUB_URL:-https://github.com}"
API_URL="${GITHUB_API_URL:-https://api.github.com}"
# Distinct per container, so several can run side by side. GitHub rejects a
# duplicate name unless --replace is passed, and silently replacing another
# live runner is a worse failure than refusing to start.
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-$$}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,docker}"
RUNNER_GROUP="${RUNNER_GROUP:-Default}"
WORK_DIR="${RUNNER_WORK_DIRECTORY:-/home/runner/_work}"

mkdir -p "${WORK_DIR}"

api() {
    # $1 = endpoint suffix, e.g. registration-token
    curl -fsS --retry 3 --retry-delay 3 -X POST \
        -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${API_URL}/repos/${GITHUB_REPOSITORY}/actions/runners/$1"
}

# --- mint a registration token ------------------------------------------
#
# Needs a classic PAT with `repo`, or a fine-grained PAT with
# Administration: read & write on this repository.
log "requesting a registration token for ${GITHUB_REPOSITORY}"
response="$(api registration-token)" \
  || fail "could not mint a registration token -- check the PAT's scopes and that it can see ${GITHUB_REPOSITORY}"

REG_TOKEN="$(jq -r '.token // empty' <<< "${response}")"
[[ -n "${REG_TOKEN}" ]] || fail "registration-token response contained no token"

# --- deregister on the way out ------------------------------------------
#
# An --ephemeral runner removes itself server-side once it completes a job,
# so `config.sh remove` is expected to be a no-op on the happy path and its
# failure is tolerated. This matters for the other exits: the container
# stopped while idle, or the job cancelled. Without it, GitHub accumulates
# "offline" runners that have to be cleaned up by hand.
deregister() {
    log "removing runner ${RUNNER_NAME}"
    local removal
    # A fresh token: the one used to register may well have expired by now.
    if removal="$(api remove-token 2>/dev/null)"; then
        ./config.sh remove --token "$(jq -r '.token // empty' <<< "${removal}")" \
            || log "config.sh remove failed (expected if the job already consumed this ephemeral runner)"
    else
        log "could not mint a removal token; the runner may linger as offline" >&2
    fi
}

RUNNER_PID=""
forward_signal() {
    if [[ -n "${RUNNER_PID}" ]]; then
        log "forwarding termination to run.sh (pid ${RUNNER_PID})"
        kill -TERM "${RUNNER_PID}" 2>/dev/null || true
    fi
}
trap forward_signal INT TERM

# --- configure ----------------------------------------------------------
#
# --ephemeral is what makes this design safe to use at all: the runner
# accepts exactly one job and then exits, so nothing a job leaves behind --
# files, processes, environment, a poisoned pip cache -- can be observed by
# the next one. Pair it with a restart policy to keep a runner available.
#
# --disableupdate keeps the version pinned in the Dockerfile honest. Drop it
# if GitHub starts refusing jobs from a version this old; the runner will
# then self-update in place, and the image should be rebuilt to match.
log "configuring ${RUNNER_NAME}"
./config.sh \
    --unattended \
    --ephemeral \
    --disableupdate \
    --url "${GITHUB_URL}/${GITHUB_REPOSITORY}" \
    --token "${REG_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "${RUNNER_LABELS}" \
    --runnergroup "${RUNNER_GROUP}" \
    --work "${WORK_DIR}"

# run.sh goes into the background rather than being exec'd, so this script
# survives to deregister afterwards. `exec` would replace the shell and
# discard the traps above, leaving a stopped container registered at GitHub
# forever.
log "waiting for a job"
./run.sh &
RUNNER_PID=$!

# `wait` returns early when a trapped signal arrives, so keep waiting until
# the child has genuinely exited. `|| true` because a runner terminated by
# signal exits non-zero and that is a normal shutdown, not a failure.
while kill -0 "${RUNNER_PID}" 2>/dev/null; do
    wait "${RUNNER_PID}" && break || true
done
wait "${RUNNER_PID}" 2>/dev/null || true
status=$?

trap - INT TERM
deregister
log "exiting with status ${status}"
exit "${status}"
