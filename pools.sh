#!/usr/bin/env bash
# The one thing to remember about the pools on this host: everything else in
# this repo is `docker compose` with GITHUB_REPOSITORY and COMPOSE_PROJECT_NAME
# set by hand, which is fine for one pool and error-prone for five. This just
# wraps that, and adds `list`, which nothing else here gives you: what's
# running, which repo it serves, and whether GitHub actually sees it as
# online -- three facts that can each be wrong independently of the others.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

POOLS_CONF="pools.conf"

# The exit status stop, restart and restart-runner use when they refuse: a
# runner is busy, or that can't be established. Distinct from 1 so a caller
# can offer --force instead of an error.
EXIT_REFUSED=3

usage() {
  cat <<'EOF'
Usage:
  ./pools.sh up    <name> <owner/repo> [count] [label] [mem] [pids]
                                                  bring a pool up (default count 2)
  ./pools.sh down  <name>                        tear a pool down (deregisters cleanly)
  ./pools.sh reset <name> <owner/repo> [count] [label] [mem] [pids]
                                                  down, then up fresh
  ./pools.sh start <name>                        bring a pool up exactly as pools.conf declares it
  ./pools.sh stop  <name> [--force]              tear a pool down unless a runner is busy
  ./pools.sh restart <name> [--force]            stop, then start, a pool pools.conf declares
  ./pools.sh restart-runner <container> [--force]
                                                  restart one runner container unless it is busy
  ./pools.sh scale <name> <count> [--force]      resize a pool pools.conf declares
  ./pools.sh list  [--json [<name>...]]          every pool this host knows about

<name> is the short label used in the project name, e.g. "jobtrack" for
gh-runner-jobtrack. It does not have to match the repo name.

[label], [mem] and [pids] are optional, trailing, and positional -- pass "-"
for one you want to leave at its default so a later one still lands in the
right slot, e.g. `./pools.sh up issue-worm leonarduk/issue-worm-pro 2
issue-worm 2g`. Omitted or "-" means "use today's default" in each case:

  [label]  extra runner label(s), comma-separated, appended after the usual
           self-hosted,linux,x64,docker,<host> set -- e.g. "issue-worm" lets
           a workflow target `runs-on: [self-hosted, issue-worm]` and reach
           only this pool, separate from the shared CI pool. Default: none
           appended.
  [mem]    per-container mem_limit, e.g. "2g". Default: 1g.
  [pids]   per-container pids_limit, e.g. "1024". Default: 512.

reset exists for the state a pool ends up in after manual `docker rm`/`stop`
surgery: mismatched images, containers still under compose's radar but not
actually healthy, GitHub's "online" flag lagging a container that already
died. `down` on such a pool can fail to find everything; `up --build` alone
can leave stale containers behind it doesn't know to touch. reset removes the
project by name first, tolerates that failing if there is nothing left to
remove, then brings up a fresh pool -- the same clean-slate operation as
deleting every container by hand, minus the part where GitHub is left with
runners nothing will ever deregister.

start, stop, restart, restart-runner and scale are for anything driving this
script on someone's behalf -- a dashboard, a cron job. start and restart
take nothing but a name, so the repo, size, label and limits can only come
from pools.conf. stop, restart and restart-runner ask GitHub first and exit
3 rather than cancel a job a runner is running -- or when GitHub can't be
asked, or none of GitHub's runners can be matched to the pool's containers,
since "unknown" is not "idle". --force skips that check. stop works on any
pool running here, declared or not; start and restart only on one
pools.conf declares. restart-runner restarts one container (named as
`docker ps` shows it, e.g. gh-runner-jobtrack-runner-1): it deregisters and
comes straight back as a fresh runner.

scale <name> <count> also only works on a pool pools.conf declares, but
resizes it in place instead of tearing it down first. Growing (or bringing
up a pool with nothing running) is just cmd_up with the new count, so it
never refuses -- there is nothing already running that scaling up could
hurt. Shrinking gets the same busy check as stop/restart, since
`docker compose up --scale` down can't be told which containers to kill,
and killing a busy one cancels its job; --force skips that check too.

list --json prints one JSON array: every pool in pools.conf, plus every
gh-runner-* project running here that pools.conf doesn't declare
("managed": false) -- the drift startRunners.sh/stopRunners.sh never touch.
"members" has one entry per container, with its docker state and the GitHub
runner it registered (null if none). "runners" counts only the GitHub
runners registered by this pool's own containers, so two pools serving one
repo are told apart; it is null when GitHub couldn't be asked. Names after
--json limit it to those pools -- worth doing from anything that polls,
since every pool costs a GitHub API call; a name that is neither declared
nor running is left out.
EOF
}

project() { printf 'gh-runner-%s' "$1"; }

die() { echo "pools.sh: $*" >&2; exit 1; }

refuse() { echo "pools.sh: $* -- --force to do it anyway" >&2; exit "$EXIT_REFUSED"; }

# The pools.conf line for <name>, as "repo count label mem pids" with "-" for
# any trailing column the line leaves out. Fails if no line declares <name>.
conf_line() {
  local want="$1" name repo count label mem pids
  [[ -f "$POOLS_CONF" ]] || return 1
  while read -r name repo count label mem pids || [[ -n ${name:-} ]]; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    if [[ "$name" == "$want" ]]; then
      printf '%s %s %s %s %s\n' "$repo" "${count:-2}" "${label:--}" "${mem:--}" "${pids:--}"
      return 0
    fi
  done < <(tr -d '\r' < "$POOLS_CONF")
  return 1
}

conf_names() {
  [[ -f "$POOLS_CONF" ]] || return 0
  local name _
  while read -r name _ || [[ -n ${name:-} ]]; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    printf '%s\n' "$name"
  done < <(tr -d '\r' < "$POOLS_CONF")
}

# Short container IDs, which are also the containers' hostnames -- and so the
# middle of the runner name entrypoint.sh registers (<host>-<hostname>-<pid>).
pool_cids() {
  docker ps -a --filter "label=com.docker.compose.project=$1" --format '{{.ID}}'
}

pool_running_count() {
  docker ps --filter "label=com.docker.compose.project=$1" --format '{{.ID}}' | wc -l | tr -d ' '
}

pool_repo() {
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^GITHUB_REPOSITORY=//p' || true
}

# One "<name> <status> <busy>" line per GitHub runner registered for <repo>.
# Fails when GitHub can't be asked.
repo_runners() {
  gh api "repos/$1/actions/runners?per_page=100" --paginate \
    --jq '.runners[] | "\(.name) \(.status) \(.busy)"' 2>/dev/null
}

# From repo_runners' lines on stdin, the one registered by container <cid>.
# Fails if that container has no runner registered.
runner_for() {
  local cid="$1" name status busy
  while read -r name status busy; do
    if [[ -n "$name" && "$name" == *"-${cid}-"* ]]; then
      printf '%s %s %s\n' "$name" "$status" "$busy"
      return 0
    fi
  done
  return 1
}

# "<matched> <online> <busy>" for the GitHub runners registered by the given
# containers. Fails when GitHub can't be asked.
pool_runner_counts() {
  local repo="$1"; shift
  local runners line status busy cid matched=0 online=0 nbusy=0
  runners="$(repo_runners "$repo")" || return 1
  for cid in "$@"; do
    line="$(runner_for "$cid" <<< "$runners")" || continue
    read -r _ status busy <<< "$line"
    matched=$((matched + 1))
    [[ "$status" == online ]] && online=$((online + 1))
    [[ "$busy" == true ]] && nbusy=$((nbusy + 1))
  done
  printf '%s %s %s\n' "$matched" "$online" "$nbusy"
}

# Exits 3 unless GitHub confirms none of pool <name>'s runners is busy.
# Advisory, not a lock: a runner can still pick up a job right after this.
require_idle() {
  local proj cids repo counts matched busy
  proj="$(project "$1")"
  cids="$(pool_cids "$proj")"
  [[ -n "$cids" ]] || return 0
  repo="$(pool_repo "$(head -1 <<< "$cids")")"
  [[ -n "$repo" ]] || refuse "can't tell which repo $proj serves, so can't check it is idle"
  # shellcheck disable=SC2086 # one short hex container ID per word
  counts="$(pool_runner_counts "$repo" $cids)" || refuse "could not ask GitHub whether $proj is busy"
  read -r matched _ busy <<< "$counts"
  # A container between jobs is briefly unregistered, but a running job
  # always has a registration -- so if not one of the pool's containers
  # matches a runner, the likelier story is that the name-matching broke,
  # and a broken match would hide a busy runner.
  (( matched > 0 )) || refuse "no runner on GitHub matches any of $proj's containers, so can't confirm it is idle"
  (( busy == 0 )) || refuse "$proj has $busy busy runner(s); this would cancel their jobs"
}

# Validates "<target> [--force]" for <verb>; <what> names the target in usage.
check_force_args() {
  local verb="$1" what="$2"; shift 2
  (( $# >= 1 && $# <= 2 )) || die "usage: ./pools.sh $verb $what [--force]"
  [[ -z "${2:-}" || "$2" == "--force" ]] || die "unknown option '$2' -- usage: ./pools.sh $verb $what [--force]"
}

json_str() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "${s//[[:cntrl:]]/}"
}

json_str_or_null() {
  if [[ -n "$1" ]]; then json_str "$1"; else printf 'null'; fi
}

cmd_up() {
  local name="$1" repo="$2" count="${3:-2}"
  local label="${4:-}" mem="${5:-}" pids="${6:-}"
  # "-" is the placeholder for "use the default", so a later positional arg
  # can be set without also having to set the ones before it.
  [[ "$label" == "-" ]] && label=""
  [[ "$mem" == "-" ]] && mem=""
  [[ "$pids" == "-" ]] && pids=""
  GITHUB_REPOSITORY="$repo" COMPOSE_PROJECT_NAME="$(project "$name")" \
    RUNNER_EXTRA_LABELS="$label" POOL_MEM_LIMIT="$mem" POOL_PIDS_LIMIT="$pids" \
    docker compose up -d --build --scale "runner=${count}"
}

cmd_down() {
  local name="$1"
  COMPOSE_PROJECT_NAME="$(project "$name")" docker compose down
}

cmd_reset() {
  local name="$1" repo="$2" count="${3:-2}"
  local label="${4:-}" mem="${5:-}" pids="${6:-}"
  COMPOSE_PROJECT_NAME="$(project "$name")" docker compose down --remove-orphans 2>/dev/null || true
  cmd_up "$name" "$repo" "$count" "$label" "$mem" "$pids"
}

cmd_start() {
  local name="${1:?usage: ./pools.sh start <name>}" line repo count label mem pids
  line="$(conf_line "$name")" \
    || die "no pool named '$name' in $POOLS_CONF -- start only brings up pools declared there"
  read -r repo count label mem pids <<< "$line"
  cmd_up "$name" "$repo" "$count" "$label" "$mem" "$pids"
}

cmd_stop() {
  check_force_args stop "<name>" "$@"
  [[ -n "${2:-}" ]] || require_idle "$1"
  cmd_down "$1"
}

cmd_restart() {
  check_force_args restart "<name>" "$@"
  conf_line "$1" >/dev/null \
    || die "no pool named '$1' in $POOLS_CONF -- restart only works on pools declared there, since it has to start them again"
  [[ -n "${2:-}" ]] || require_idle "$1"
  cmd_down "$1"
  cmd_start "$1"
}

cmd_restart_runner() {
  check_force_args restart-runner "<container>" "$@"
  local container="$1" proj cid repo runners line busy counts matched
  proj="$(docker inspect "$container" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null)" \
    || die "no container named '$container' on this host"
  [[ "$proj" == gh-runner-* ]] || die "'$container' isn't a runner container (compose project '${proj}')"
  if [[ -z "${2:-}" ]]; then
    cid="$(docker inspect "$container" --format '{{.Config.Hostname}}')"
    repo="$(pool_repo "$container")"
    [[ -n "$repo" ]] || refuse "can't tell which repo $container serves, so can't check it is idle"
    runners="$(repo_runners "$repo")" || refuse "could not ask GitHub whether $container is busy"
    if line="$(runner_for "$cid" <<< "$runners")"; then
      read -r _ _ busy <<< "$line"
      [[ "$busy" != true ]] || refuse "$container is running a job; restarting would cancel it"
    else
      # No registration is normal for a container between jobs or stuck
      # failing to register -- what restarting it is for -- unless none of
      # its pool matches either, which says the name-matching broke.
      # shellcheck disable=SC2046 # one short hex container ID per word
      counts="$(pool_runner_counts "$repo" $(pool_cids "$proj"))" \
        || refuse "could not ask GitHub whether $container is busy"
      read -r matched _ _ <<< "$counts"
      (( matched > 0 )) || refuse "no runner on GitHub matches any of $proj's containers, so can't confirm $container is idle"
    fi
  fi
  docker restart -t 60 "$container"
}

cmd_scale() {
  (( $# >= 2 && $# <= 3 )) || die "usage: ./pools.sh scale <name> <count> [--force]"
  local name="$1" count="$2"
  [[ -z "${3:-}" || "$3" == "--force" ]] \
    || die "unknown option '$3' -- usage: ./pools.sh scale <name> <count> [--force]"
  [[ "$count" =~ ^[0-9]+$ ]] \
    || die "usage: ./pools.sh scale <name> <count> [--force] -- <count> must be a non-negative integer"
  local line repo label mem pids current
  line="$(conf_line "$name")" \
    || die "no pool named '$name' in $POOLS_CONF -- scale only works on pools declared there"
  read -r repo _ label mem pids <<< "$line"
  current="$(pool_running_count "$(project "$name")")"
  # Growing (or starting from nothing) never touches a running container, so
  # it needs no busy check. Shrinking does: `docker compose up --scale` down
  # picks which containers die, and a busy one dying cancels its job.
  (( count >= current )) || { [[ -n "${3:-}" ]] || require_idle "$name"; }
  cmd_up "$name" "$repo" "$count" "$label" "$mem" "$pids"
}

cmd_list() {
  local projects
  projects="$(docker ps -a --format '{{.Label "com.docker.compose.project"}}' | grep '^gh-runner-' | sort -u || true)"
  if [[ -z "$projects" ]]; then
    echo "no pools running on this host"
    return 0
  fi
  printf '%-28s %-42s %-12s %s\n' PROJECT REPO CONTAINERS GITHUB
  while IFS= read -r proj; do
    local cid repo total running online
    cid="$(docker ps -a --filter "label=com.docker.compose.project=${proj}" --format '{{.ID}}' | head -1)"
    repo="$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | sed -n 's/^GITHUB_REPOSITORY=//p')"
    total="$(docker ps -a --filter "label=com.docker.compose.project=${proj}" --format '{{.ID}}' | wc -l | tr -d ' ')"
    running="$(docker ps --filter "label=com.docker.compose.project=${proj}" --format '{{.ID}}' | wc -l | tr -d ' ')"
    online="?"
    if [[ -n "$repo" ]] && command -v gh >/dev/null 2>&1; then
      online="$(gh api "repos/${repo}/actions/runners" \
        --jq '[.runners[] | select(.status=="online")] | length' 2>/dev/null || echo '?')"
    fi
    printf '%-28s %-42s %-12s online=%s\n' "$proj" "${repo:-unknown}" "${running}/${total}" "$online"
  done <<< "$projects"
}

cmd_list_json() {
  local all names proj name line managed repo desired label containers cids known rlines
  local cid cname cstate cstatus rname rstatus rbusy rb runner members sep
  local total running online busy runners first=1
  if (( $# )); then
    names="$(printf '%s\n' "$@")"
  else
    # Not piped straight into grep: a docker failure has to fail the
    # command, not read as "no pools".
    all="$(docker ps -a --format '{{.Label "com.docker.compose.project"}}')"
    names="$(conf_names)"
    while IFS= read -r proj; do
      [[ -z "$proj" ]] && continue
      name="${proj#gh-runner-}"
      grep -qxF "$name" <<< "$names" || names+=$'\n'"$name"
    done < <(grep '^gh-runner-' <<< "$all" | sort -u || true)
  fi

  printf '['
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    proj="$(project "$name")"
    managed=false repo="" desired=null label=null
    if line="$(conf_line "$name")"; then
      managed=true
      read -r repo desired label _ _ <<< "$line"
      [[ "$desired" =~ ^[0-9]+$ ]] || desired=null
      if [[ "$label" == "-" ]]; then label=null; else label="$(json_str "$label")"; fi
    fi
    containers="$(docker ps -a --filter "label=com.docker.compose.project=${proj}" \
      --format $'{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}')"
    # Only reachable for a name passed on the command line.
    [[ "$managed" == false && -z "$containers" ]] && continue
    cids="$(cut -f1 <<< "$containers")"
    [[ -z "$repo" && -n "$cids" ]] && repo="$(pool_repo "$(head -1 <<< "$cids")")"
    known=false rlines=""
    if [[ -z "$cids" ]]; then
      known=true
    elif [[ -n "$repo" ]] && rlines="$(repo_runners "$repo")"; then
      known=true
    fi
    total=0 running=0 online=0 busy=0 members="" sep=""
    while IFS=$'\t' read -r cid cname cstate cstatus; do
      [[ -z "$cid" ]] && continue
      total=$((total + 1))
      [[ "$cstate" == running ]] && running=$((running + 1))
      runner=null
      if [[ "$known" == true ]] && line="$(runner_for "$cid" <<< "$rlines")"; then
        read -r rname rstatus rbusy <<< "$line"
        [[ "$rstatus" == online ]] && online=$((online + 1))
        rb=false
        if [[ "$rbusy" == true ]]; then rb=true; busy=$((busy + 1)); fi
        runner="{\"name\":$(json_str "$rname"),\"status\":$(json_str "$rstatus"),\"busy\":${rb}}"
      fi
      members+="${sep}{\"container\":$(json_str "$cname"),\"id\":$(json_str "$cid"),\"state\":$(json_str "$cstate"),\"status\":$(json_str "$cstatus"),\"runner\":${runner}}"
      sep=","
    done <<< "$containers"
    if [[ "$known" == true ]]; then
      runners="{\"online\":${online},\"busy\":${busy}}"
    else
      runners=null
    fi
    (( first )) || printf ','
    first=0
    printf '{"name":%s,"project":%s,"repo":%s,"managed":%s,"desired":%s,"label":%s,"containers":{"total":%s,"running":%s},"runners":%s,"members":[%s]}' \
      "$(json_str "$name")" "$(json_str "$proj")" "$(json_str_or_null "$repo")" \
      "$managed" "$desired" "$label" "$total" "$running" "$runners" "$members"
  done <<< "$names"
  printf ']\n'
}

case "${1:-}" in
  up)    shift; cmd_up "$@" ;;
  down)  shift; cmd_down "$@" ;;
  reset) shift; cmd_reset "$@" ;;
  start) shift; cmd_start "$@" ;;
  stop)  shift; cmd_stop "$@" ;;
  restart) shift; cmd_restart "$@" ;;
  restart-runner) shift; cmd_restart_runner "$@" ;;
  scale) shift; cmd_scale "$@" ;;
  list)
    case "${2:-}" in
      "")     cmd_list ;;
      --json) shift 2; cmd_list_json "$@" ;;
      *)      usage; exit 1 ;;
    esac ;;
  *) usage; exit 1 ;;
esac
