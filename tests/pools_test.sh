#!/usr/bin/env bash
# Exercises pools.sh's start/stop/restart/restart-runner/scale/sync/list --json
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
      gh-runner-worm-runner-1|abc123def456) id=abc123def456 proj=gh-runner-worm repo=o/r extra=",worm-label" ;;
      gh-runner-worm-runner-2|222222222222) id=222222222222 proj=gh-runner-worm repo=o/r extra=",worm-label" ;;
      gh-runner-stray-runner-1|fff000fff000) id=fff000fff000 proj=gh-runner-stray repo="${FAKE_STRAY_REPO:-o/stray}" extra=",stray-label" ;;
      unrelated-db) id=333333333333 proj=something-else repo="" extra="" ;;
      *) echo "Error: No such object: $2" >&2; exit 1 ;;
    esac
    case "$args" in
      *compose.project*) echo "$proj" ;;
      *Hostname*) echo "$id" ;;
      # 2g, and compose.yaml's default pids_limit.
      *HostConfig*) echo "2147483648 512" ;;
      *) printf 'GITHUB_REPOSITORY=%s\nRUNNER_LABELS=self-hosted,linux,x64,docker,box%s\n' "$repo" "$extra" ;;
    esac ;;
  restart) echo "docker-restart ${*:2}" ;;
  compose)
    [[ -n "${FAKE_COMPOSE_FAIL:-}" ]] && { echo "compose: no Docker daemon" >&2; exit 1; }
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

# scale writes the new count into its pools.conf, so it gets a copy of its
# own. idle has no count column here (pools.sh reads that as 2), to check
# one gets added.
c="$tmp/scale"
mkdir -p "$c"
cp "$here/../pools.sh" "$c/"
printf '# keep me\nworm   o/r    2    worm-label   2g   1024\nidle   o/idle\n' > "$c/pools.conf"
q="$c/pools.sh"

check "scale up on an idle pool" 0 \
  "repo=o/idle project=gh-runner-idle label= mem= pids= :: up -d --build --scale runner=3" -- bash "$q" scale idle 3
check "scale adds a count to a pools.conf line that had none" 0 "" -- grep -qxF "idle   o/idle 3" "$c/pools.conf"
check "scale up on a pool with a busy runner succeeds" 0 \
  "repo=o/r project=gh-runner-worm label=worm-label mem=2g pids=1024 :: up -d --build --scale runner=3" \
  -- env FAKE_BUSY=true bash "$q" scale worm 3
check "scale writes the new count to pools.conf" 0 "" -- grep -qxF "worm   o/r    3    worm-label   2g   1024" "$c/pools.conf"
check "scale down on an idle pool" 0 \
  "repo=o/r project=gh-runner-worm label=worm-label mem=2g pids=1024 :: up -d --build --scale runner=1" \
  -- bash "$q" scale worm 1
check "scale says what it changed in pools.conf" 0 "pools.conf now declares worm at 10 (was 1)" -- bash "$q" scale worm 10
check "scale keeps the columns after a wider count in place" 0 "" \
  -- grep -qxF "worm   o/r    10   worm-label   2g   1024" "$c/pools.conf"
check "scale leaves the other lines alone" 0 "" -- grep -qxF "# keep me" "$c/pools.conf"
cp "$c/pools.conf" "$c/before"
check "scale to the size pools.conf already declares" 0 ":: up -d --build --scale runner=10" -- bash "$q" scale worm 10
check "... doesn't rewrite pools.conf" 0 "" -- cmp "$c/pools.conf" "$c/before"
check "scale down with a busy runner refuses" 3 "1 busy runner" -- env FAKE_BUSY=true bash "$q" scale worm 1
check "a refused scale leaves pools.conf alone" 0 "" -- cmp "$c/pools.conf" "$c/before"
check "a failed scale fails" 1 "no Docker daemon" -- env FAKE_COMPOSE_FAIL=1 bash "$q" scale worm 11
check "a failed scale leaves pools.conf alone" 0 "" -- cmp "$c/pools.conf" "$c/before"
check "scale down --force skips the busy check" 0 \
  "repo=o/r project=gh-runner-worm label=worm-label mem=2g pids=1024 :: up -d --build --scale runner=1" \
  -- env FAKE_BUSY=true bash "$q" scale worm 1 --force
check "scale refuses an undeclared pool" 1 "no pool named 'stray'" -- bash "$q" scale stray 2
check "scale rejects a non-numeric count" 1 "usage: ./pools.sh scale" -- bash "$q" scale worm abc
check "scale rejects an unknown option" 1 "unknown option '--bogus'" -- bash "$q" scale worm 2 --bogus
check "scale rejects extra arguments" 1 "usage: ./pools.sh scale" -- bash "$q" scale worm 2 --force extra

# declare appends to its pools.conf, so it gets a copy of its own too: one
# whose last line has no newline, to check the new line isn't glued on.
d="$tmp/declare"
mkdir -p "$d"
cp "$here/../pools.sh" "$d/"
printf '# keep me\nworm   o/r    2    worm-label   2g   1024' > "$d/pools.conf"
cp "$d/pools.conf" "$d/before"
check "declare refuses a pool that's already declared" 1 "'worm' is already declared" -- bash "$d/pools.sh" declare worm o/other
check "declare refuses a bad name" 1 "<name> must be lowercase" -- bash "$d/pools.sh" declare Bad_Name o/r
check "declare refuses a bad repo" 1 "must look like owner/repo" -- bash "$d/pools.sh" declare fresh not-a-repo
check "declare refuses a bad count" 1 "must be a non-negative integer" -- bash "$d/pools.sh" declare fresh o/fresh two
check "declare rejects extra arguments" 1 "usage: ./pools.sh declare" -- bash "$d/pools.sh" declare fresh o/fresh 1 extra
check "a refused declare leaves pools.conf alone" 0 "" -- cmp "$d/pools.conf" "$d/before"
check "declare adds a line" 0 "pools.conf now declares fresh (o/fresh) at 1" -- bash "$d/pools.sh" declare fresh o/fresh
check "... on a line of its own" 0 "" -- grep -qE '^fresh +o/fresh +1$' "$d/pools.conf"
check "... after the lines already there" 0 "" -- grep -qxF "worm   o/r    2    worm-label   2g   1024" "$d/pools.conf"
check "a declared pool can be started" 0 \
  "repo=o/fresh project=gh-runner-fresh label= mem= pids= :: up -d --build --scale runner=1" -- bash "$d/pools.sh" start fresh
e="$tmp/declare-new"
mkdir -p "$e"
cp "$here/../pools.sh" "$e/"
check "declare creates a missing pools.conf" 0 "now declares fresh (o/fresh) at 3" -- bash "$e/pools.sh" declare fresh o/fresh 3
check "... with just that line" 0 "" -- grep -qE '^fresh +o/fresh +3$' "$e/pools.conf"

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

# sync rewrites its pools.conf, so it gets a copy of its own. worm's count
# is two digits here, to check the columns after it stay put.
unset FAKE_STRAY_REPO
s="$tmp/sync"
mkdir -p "$s"
cp "$here/../pools.sh" "$s/"
# idle and bare are declared with no containers (stopped, or scaled to 0),
# bare with no count column, which pools.sh reads as 2.
printf '# keep me\nworm   o/r    10   worm-label   2g   1024\nidle   o/idle 1\nbare   o/bare\n' > "$s/pools.conf"
cp "$s/pools.conf" "$s/original"
{
  printf '# keep me\nworm   o/r    2    worm-label   2g   1024\nidle   o/idle 0\nbare   o/bare 0\n'
  printf '%-20s %-53s %s   stray-label   2g\n' stray o/stray 1
} > "$s/expected"

check "sync --dry-run reports a changed count" 0 "worm: 10 -> 2" -- bash "$s/pools.sh" sync --dry-run
check "sync --dry-run reports an undeclared pool" 0 "stray: added (o/stray, 1)" -- bash "$s/pools.sh" sync --dry-run
check "sync --dry-run leaves pools.conf alone" 0 "" -- cmp "$s/pools.conf" "$s/original"
check "sync sets a declared pool with no containers to 0" 0 "idle: 1 -> 0" -- bash "$s/pools.sh" sync --dry-run
check "... and one with no count column" 0 "bare: 2 (the default) -> 0" -- bash "$s/pools.sh" sync
check "a pool synced to 0 lists as wanting 0" 0 '"name":"idle","project":"gh-runner-idle","repo":"o/idle","managed":true,"desired":0' -- bash "$s/pools.sh" list --json idle
check "sync rewrites counts and adds undeclared pools with their label and limits" 0 "" -- diff "$s/expected" "$s/pools.conf"
check "sync keeps the previous pools.conf" 0 "" -- cmp "$s/pools.conf.bak" "$s/original"
check "sync again changes nothing" 0 "already matches" -- bash "$s/pools.sh" sync
check "an adopted pool is declared afterwards" 0 \
  '"name":"stray","project":"gh-runner-stray","repo":"o/stray","managed":true,"desired":1,"label":"stray-label"' \
  -- env FAKE_CID=fff000fff000 bash "$s/pools.sh" list --json stray
check "sync rejects an unknown option" 1 "usage: ./pools.sh sync" -- bash "$s/pools.sh" sync --bogus

if (( fails )); then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
