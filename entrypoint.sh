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
#
# Distinct per container, note, and not per registration: $$ is 1 in every
# container (this script is PID 1) and $(hostname) is Config.Hostname, which
# survives a restart. The same container therefore re-registers under the
# same name, which is why reclaim_orphaned_name() below exists. #153.
#
# RUNNER_HOST_LABEL, when set, prefixes the name so that the runner list on
# GitHub says which physical machine a runner is on. Container hostnames are
# random hex, which is no help at all once runners live on more than one box.
RUNNER_NAME="${RUNNER_NAME:-${RUNNER_HOST_LABEL:+${RUNNER_HOST_LABEL}-}$(hostname)-$$}"
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

# The GET and DELETE that reclaim_orphaned_name() needs. Kept separate from
# api() rather than giving that one a method parameter: every existing caller
# of api() is a POST that mints a token, and a helper whose verb comes from an
# argument is one typo away from POSTing to a delete endpoint.
api_method() {
    # $1 = HTTP method, $2 = appended to .../actions/runners verbatim, so the
    # caller writes its own leading "/" or "?". Not assembled here: a helper
    # that inserts the "/" itself turns a query string into ".../runners/?..",
    # which GitHub 404s -- and the failure is silent, because the caller below
    # treats an unreadable listing as "nothing to reclaim".
    curl -fsS --retry 3 --retry-delay 3 -X "$1" \
        -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${API_URL}/repos/${GITHUB_REPOSITORY}/actions/runners$2"
}

# --- mint a registration token ------------------------------------------
#
# Needs a classic PAT with `repo`, or a fine-grained PAT with
# Administration: read & write on the repository being served.
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
# shellcheck disable=SC2329 # invoked indirectly via `trap` below
forward_signal() {
    if [[ -n "${RUNNER_PID}" ]]; then
        log "forwarding termination to run.sh (pid ${RUNNER_PID})"
        kill -TERM "${RUNNER_PID}" 2>/dev/null || true
    fi
    # run.sh is only a wrapper. The process that RUNNER_MANUALLY_TRAP_SIG=1
    # arms is the Runner.Listener underneath it, and a signal sent to the
    # wrapper never reaches it -- so the listener keeps running, the `wait`
    # below never returns, and the container is SIGKILLed with deregister()
    # unreached. That is what left runners registered-but-offline with no
    # container behind them, and left this container's own .runner on disk
    # for `restart: always` to trip over. Measured before this: `docker stop
    # -t 60` waited the full 60s and was killed anyway.
    if pkill -TERM -f 'Runner\.Listener' 2>/dev/null; then
        log "forwarding termination to Runner.Listener"
    fi
}
trap forward_signal INT TERM

# A container that was killed rather than stopped -- SIGKILL after the grace
# period, `docker kill`, a host crash -- leaves .runner and .credentials
# behind. `restart: always` then restarts *that same container*, and config.sh
# refuses with "Cannot configure the runner because it is already configured",
# so it crash-loops instead of rejoining the pool. Clear the leftovers and
# register afresh.
#
# This does NOT come back as a new runner. RUNNER_NAME is the same string it
# was: $$ is 1 in every container (entrypoint.sh is PID 1 -- exec-form
# ENTRYPOINT, no init), and $(hostname) is the container's Config.Hostname,
# which a restart preserves. Reclaiming the name we left on GitHub is
# reclaim_orphaned_name()'s job, below; clearing .runner here only settles the
# local half.
if [[ -f .runner ]]; then
    log "found a stale runner configuration from a killed container; clearing it"
    if stale_removal="$(api remove-token 2>/dev/null)"; then
        ./config.sh remove --token "$(jq -r '.token // empty' <<< "${stale_removal}")" \
            || log "config.sh remove failed; deleting the local configuration by hand"
    fi
    rm -f .runner .credentials .credentials_rsaparams
fi

# --- reclaim our own name -----------------------------------------------
#
# The block above can leave a registration behind on GitHub: the removal is
# nested inside the remove-token call, so when minting that token fails -- a
# starved host, a network blip, an expired PAT -- nothing is removed there,
# yet .runner is deleted locally regardless. config.sh then registers under a
# name GitHub already knows and fails with "A runner exists with the same
# name", which `restart: always` turns into a crash loop. #153.
#
# Deliberately not --replace, for the reason given where RUNNER_NAME is built:
# replacing a *live* runner silently is worse than refusing to start. Only an
# offline runner under our own exact name is reclaimed. That is by definition
# our own orphan -- names are unique per container, and a container is one
# runner -- so nobody else's work is cut off. A same-named runner that is
# online still collides, and we still refuse, exactly as before.
reclaim_orphaned_name() {
    local listing id status
    # per_page=100 covers any plausible pool; a name missing from the first
    # page just means no reclaim, and config.sh reports the collision as it
    # does today rather than this masking it.
    listing="$(api_method GET "?per_page=100" 2>/dev/null)" || {
        log "could not list runners to check for an orphaned '${RUNNER_NAME}'; continuing" >&2
        return 0
    }

    id="$(jq -r --arg n "${RUNNER_NAME}" \
        '.runners[]? | select(.name == $n) | .id' <<< "${listing}" | head -n1)"
    [[ -n "${id}" ]] || return 0

    status="$(jq -r --arg n "${RUNNER_NAME}" \
        '.runners[]? | select(.name == $n) | .status' <<< "${listing}" | head -n1)"
    if [[ "${status}" != "offline" ]]; then
        log "a runner named ${RUNNER_NAME} is already ${status} on GitHub; not touching it" >&2
        return 0
    fi

    log "reclaiming our own offline registration ${RUNNER_NAME} (id ${id})"
    api_method DELETE "/${id}" >/dev/null 2>&1 \
        || log "could not delete the orphaned registration; config.sh will report the collision" >&2
}

reclaim_orphaned_name

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
