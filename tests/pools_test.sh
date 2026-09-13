#!/usr/bin/env bash
# Exercises pools.sh's start/stop/restart/restart-runner/scale/list --json
# against stub docker and gh on PATH: no Docker daemon, no GitHub, nothing
# real is touched.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$here/../pools.sh" "$tmp/"
printf 'worm   o/r    2   worm-label   2g   1024\nidle   o/idle 1\n' > "$tmp/pools.conf"

# The stub host: "worm" (declared) with one registered, running container
# and one exited container that never registered; "stray" (running, not
# declared) with one container; "idle" declared but with no containers; and
# "unrelated-db", a container that isn't a runner at all.
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$1" in
  ps)
    case "$args" in
      *"project=gh-runner-worm"*)
        if [[ "$args" == *".Names"* ]]; then
          printf 'abc123def456\tgh-runner-worm-runner-1\trunning\tUp 2 hours\n'
          printf '222222222222\tgh-runner-worm-runner-2\texited\tExited (1) 3 minutes ago\n'
        else
          printf 'abc123def456\n222222222222\n'
        fi ;;
      *"project=gh-runner-stray"*)
        if [[ "$args" == *".Names"* ]]; then
          printf 'fff000fff000\tgh-runner-stray-runner-1\trunning\tUp 1 hour\n'
        else
          echo fff000fff000
        fi ;;
      *"--filter"*) ;;
      *) printf 'gh-runner-worm\ngh-runner-stray\nunrelated\n\n' ;;
    esac ;;
  inspect)
    case "$2" in
      gh-runner-worm-runner-1|abc123def456) id=abc123def456 proj=gh-runner-worm repo=o/r ;;
      gh-runner-worm-runner-2|222222222222) id=222222222222 proj=gh-runner-worm repo=o/r ;;
      gh-runner-stray-runner-1|fff000fff000) id=fff000fff000 proj=gh-runner-stray repo="${FAKE_STRAY_REPO:-o/stray}" ;;
      unrelated-db) id=333333333333 proj=something-else repo="" ;;
      *) echo "Error: No such object: $2" >&2; exit 1 ;;
    esac
    case "$args" in
      *compose.project*) echo "$proj" ;;
      *Hostname*) echo "$id" ;;
      *) printf 'GITHUB_REPOSITORY=%s\n' "$repo" ;;
    esac ;;
  restart) echo "docker-restart ${*:2}" ;;
  compose)
    echo "compose repo=${GITHUB_REPOSITORY:-} project=${COMPOSE_PROJECT_NAME:-} label=${RUNNER_EXTRA_LABELS:-} mem=${POOL_MEM_LIMIT:-} pids=${POOL_PIDS_LIMIT:-} :: ${*:2}" ;;
esac
EOF

# One runner for FAKE_CID's container, plus a busy runner on another host
# that must never be counted against this host's pools.
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FAKE_GH_FAIL:-}" ]] && exit 1
echo "somehost-${FAKE_CID:-abc123def456}-42 online ${FAKE_BUSY:-false}"
echo "otherhost-999999999999-1 online true"
EOF
chmod +x "$tmp/bin/docker" "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"

json_ok() {
  if command -v jq >/dev/null 2>&1; then jq -e . >/dev/null
  else python -m json.tool >/dev/null
  fi
}

fails=0
# check <description> <expected exit> <expected output substring> -- <command...>
check() {
  local desc="$1" want_status="$2" want_out="$3"
  shift 4
  local out status=0
  out="$("$@" 2>&1)" || status=$?
  if [[ "$status" == "$want_status" && "$out" == *"$want_out"* ]]; then
    echo "ok   $desc"
  else
    echo "FAIL $desc: exit $status (want $want_status), output: $out"
    fails=$((fails + 1))
  fi
}

p="$tmp/pools.sh"

check "stop refuses while a runner is busy" 3 "1 busy runner" -- env FAKE_BUSY=true bash "$p" stop worm
check "stop refuses when GitHub can't be asked" 3 "could not ask GitHub" -- env FAKE_GH_FAIL=1 bash "$p" stop worm
check "stop refuses when no runner matches" 3 "can't confirm it is idle" -- env FAKE_CID=000000000000 bash "$p" stop worm
check "stop an idle pool" 0 "project=gh-runner-worm label= mem= pids= :: down" -- bash "$p" stop worm
check "stop --force skips the check" 0 ":: down" -- env FAKE_BUSY=true FAKE_GH_FAIL=1 bash "$p" stop worm --force
check "stop a pool with no containers" 0 "project=gh-runner-idle label= mem= pids= :: down" -- bash "$p" stop idle
check "stop an undeclared running pool" 0 "project=gh-runner-stray label= mem= pids= :: down" -- env FAKE_CID=fff000fff000 bash "$p" stop stray
check "stop rejects an unknown option" 1 "unknown option '--bogus'" -- bash "$p" stop worm --bogus
check "stop rejects extra arguments" 1 "usage: ./pools.sh stop" -- bash "$p" stop worm --force extra

check "start uses the pools.conf line" 0 \
  "repo=o/r project=gh-runner-worm label=worm-label mem=2g pids=1024 :: up -d --build --scale runner=2" -- bash "$p" start worm
check "start defaults the omitted columns" 0 \
  "repo=o/idle project=gh-runner-idle label= mem= pids= :: up -d --build --scale runner=1" -- bash "$p" start idle
check "start refuses an undeclared pool" 1 "no pool named 'stray'" -- bash "$p" start stray

check "restart an idle pool stops it" 0 "project=gh-runner-worm label= mem= pids= :: down" -- bash "$p" restart worm
check "restart an idle pool starts it from pools.conf" 0 \
  "repo=o/r project=gh-runner-worm label=worm-label mem=2g pids=1024 :: up -d --build --scale runner=2" -- bash "$p" restart worm
check "restart refuses while a runner is busy" 3 "1 busy runner" -- env FAKE_BUSY=true bash "$p" restart worm
check "restart --force skips the check" 0 ":: up -d --build" -- env FAKE_BUSY=true bash "$p" restart worm --force
check "restart refuses an undeclared pool" 1 "no pool named 'stray'" -- env FAKE_CID=fff000fff000 bash "$p" restart stray

check "restart-runner an idle runner" 0 "docker-restart -t 60 gh-runner-worm-runner-1" -- bash "$p" restart-runner gh-runner-worm-runner-1
check "restart-runner refuses a busy runner" 3 "running a job" -- env FAKE_BUSY=true bash "$p" restart-runner gh-runner-worm-runner-1
check "restart-runner --force skips the check" 0 "docker-restart -t 60 gh-runner-worm-runner-1" -- env FAKE_BUSY=true bash "$p" restart-runner gh-runner-worm-runner-1 --force
check "restart-runner refuses when GitHub can't be asked" 3 "could not ask GitHub" -- env FAKE_GH_FAIL=1 bash "$p" restart-runner gh-runner-worm-runner-1
check "restart-runner an unregistered runner whose pool matches" 0 \
  "docker-restart -t 60 gh-runner-worm-runner-2" -- env FAKE_BUSY=true bash "$p" restart-runner gh-runner-worm-runner-2
check "restart-runner refuses when nothing in the pool matches" 3 "can't confirm gh-runner-stray-runner-1 is idle" -- bash "$p" restart-runner gh-runner-stray-runner-1
check "restart-runner refuses a container that isn't a runner" 1 "isn't a runner container" -- bash "$p" restart-runner unrelated-db
check "restart-runner refuses a container that doesn't exist" 1 "no container named 'nosuch'" -- bash "$p" restart-runner nosuch

check "scale up on an idle pool" 0 \
  "repo=o/idle project=gh-runner-idle label= mem= pids= :: up -d --build --scale runner=3" -- bash "$p" scale idle 3
check "scale up on a pool with a busy runner succeeds" 0 \
  "repo=o/r project=gh-runner-worm label=worm-label mem=2g pids=1024 :: up -d --build --scale runner=3" \
  -- env FAKE_BUSY=true bash "$p" scale worm 3
check "scale down on an idle pool" 0 \
  "repo=o/r project=gh-runner-worm label=worm-label mem=2g pids=1024 :: up -d --build --scale runner=1" \
  -- bash "$p" scale worm 1
check "scale down with a busy runner refuses" 3 "1 busy runner" -- env FAKE_BUSY=true bash "$p" scale worm 1
check "scale down --force skips the busy check" 0 \
  "repo=o/r project=gh-runner-worm label=worm-label mem=2g pids=1024 :: up -d --build --scale runner=1" \
  -- env FAKE_BUSY=true bash "$p" scale worm 1 --force
check "scale refuses an undeclared pool" 1 "no pool named 'stray'" -- bash "$p" scale stray 2
check "scale rejects a non-numeric count" 1 "usage: ./pools.sh scale" -- bash "$p" scale worm abc
check "scale rejects an unknown option" 1 "unknown option '--bogus'" -- bash "$p" scale worm 2 --bogus
check "scale rejects extra arguments" 1 "usage: ./pools.sh scale" -- bash "$p" scale worm 2 --force extra

check "list --json counts only this pool's runners and lists its containers" 0 \
  '"name":"worm","project":"gh-runner-worm","repo":"o/r","managed":true,"desired":2,"label":"worm-label","containers":{"total":2,"running":1},"runners":{"online":1,"busy":1},"members":[{"container":"gh-runner-worm-runner-1","id":"abc123def456","state":"running","status":"Up 2 hours","runner":{"name":"somehost-abc123def456-42","status":"online","busy":true}},{"container":"gh-runner-worm-runner-2","id":"222222222222","state":"exited","status":"Exited (1) 3 minutes ago","runner":null}]}' \
  -- env FAKE_BUSY=true bash "$p" list --json
check "list --json includes undeclared pools" 0 '"name":"stray","project":"gh-runner-stray","repo":"o/stray","managed":false' -- bash "$p" list --json
check "list --json gives a pool with no containers no members" 0 '"name":"idle","project":"gh-runner-idle","repo":"o/idle","managed":true,"desired":1,"label":null,"containers":{"total":0,"running":0},"runners":{"online":0,"busy":0},"members":[]}' -- bash "$p" list --json
check "list --json drops a name nobody knows" 0 "[]" -- bash "$p" list --json nosuch
check "list rejects an unknown option" 1 "Usage:" -- bash "$p" list --bogus

if FAKE_GH_FAIL=1 bash "$p" list --json worm | grep -qF '"runners":null,"members":[{"container":"gh-runner-worm-runner-1","id":"abc123def456","state":"running","status":"Up 2 hours","runner":null}'; then
  echo "ok   list --json reports runners null, and no member runners, when GitHub can't be asked"
else
  echo "FAIL list --json reports runners null, and no member runners, when GitHub can't be asked"
  fails=$((fails + 1))
fi

for scenario in plain awkward; do
  if [[ "$scenario" == awkward ]]; then export FAKE_STRAY_REPO=$'o/we"ird\\\tname'; fi
  if bash "$p" list --json | json_ok; then
    echo "ok   list --json is valid JSON ($scenario)"
  else
    echo "FAIL list --json is valid JSON ($scenario)"
    fails=$((fails + 1))
  fi
done

if (( fails )); then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
