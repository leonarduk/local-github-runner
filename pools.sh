#!/usr/bin/env bash
# The one thing to remember about the pools on this host: everything else in
# this repo is `docker compose` with GITHUB_REPOSITORY and COMPOSE_PROJECT_NAME
# set by hand, which is fine for one pool and error-prone for five. This just
# wraps that, and adds `list`, which nothing else here gives you: what's
# running, which repo it serves, and whether GitHub actually sees it as
# online -- three facts that can each be wrong independently of the others.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

usage() {
  cat <<'EOF'
Usage:
  ./pools.sh up    <name> <owner/repo> [count]   bring a pool up (default count 2)
  ./pools.sh down  <name>                        tear a pool down (deregisters cleanly)
  ./pools.sh reset <name> <owner/repo> [count]    down, then up fresh
  ./pools.sh list                                 every pool this host knows about

<name> is the short label used in the project name, e.g. "jobtrack" for
gh-runner-jobtrack. It does not have to match the repo name.

reset exists for the state a pool ends up in after manual `docker rm`/`stop`
surgery: mismatched images, containers still under compose's radar but not
actually healthy, GitHub's "online" flag lagging a container that already
died. `down` on such a pool can fail to find everything; `up --build` alone
can leave stale containers behind it doesn't know to touch. reset removes the
project by name first, tolerates that failing if there is nothing left to
remove, then brings up a fresh pool -- the same clean-slate operation as
deleting every container by hand, minus the part where GitHub is left with
runners nothing will ever deregister.
EOF
}

project() { printf 'gh-runner-%s' "$1"; }

cmd_up() {
  local name="$1" repo="$2" count="${3:-2}"
  GITHUB_REPOSITORY="$repo" COMPOSE_PROJECT_NAME="$(project "$name")" \
    docker compose up -d --build --scale "runner=${count}"
}

cmd_down() {
  local name="$1"
  COMPOSE_PROJECT_NAME="$(project "$name")" docker compose down
}

cmd_reset() {
  local name="$1" repo="$2" count="${3:-2}"
  COMPOSE_PROJECT_NAME="$(project "$name")" docker compose down --remove-orphans 2>/dev/null || true
  cmd_up "$name" "$repo" "$count"
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

case "${1:-}" in
  up)    shift; cmd_up "$@" ;;
  down)  shift; cmd_down "$@" ;;
  reset) shift; cmd_reset "$@" ;;
  list)  cmd_list ;;
  *) usage; exit 1 ;;
esac
