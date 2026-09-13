#!/usr/bin/env bash
# Exercises pools.sh's start/stop/list --json against stub docker and gh on
# PATH: no Docker daemon, no GitHub, nothing real is touched.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$here/../pools.sh" "$tmp/"
printf 'worm   o/r    2   worm-label   2g   1024\nidle   o/idle 1\n' > "$tmp/pools.conf"

# Pools on the stub host: "worm" (declared, one container) and "stray"
# (running, undeclared). "idle" is declared but has no containers.
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$1" in
  ps)
    if   [[ "$args" == *"project=gh-runner-worm"* ]]; then echo abc123def456
    elif [[ "$args" == *"project=gh-runner-stray"* ]]; then echo fff000fff000
    elif [[ "$args" == *"--filter"* ]]; then :
    else printf 'gh-runner-worm\ngh-runner-stray\nunrelated\n\n'; fi ;;
  inspect)
    if [[ "$2" == fff000fff000 ]]; then printf 'GITHUB_REPOSITORY=%s\n' "${FAKE_STRAY_REPO:-o/stray}"
    else echo GITHUB_REPOSITORY=o/r; fi ;;
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

check "list --json counts only this pool's runners" 0 \
  '"name":"worm","project":"gh-runner-worm","repo":"o/r","managed":true,"desired":2,"label":"worm-label","containers":{"total":1,"running":1},"runners":{"online":1,"busy":1}' \
  -- env FAKE_BUSY=true bash "$p" list --json
check "list --json includes undeclared pools" 0 '"name":"stray","project":"gh-runner-stray","repo":"o/stray","managed":false' -- bash "$p" list --json
check "list --json has runners null when GitHub can't be asked" 0 '"name":"worm"' -- env FAKE_GH_FAIL=1 bash "$p" list --json
check "list --json drops a name nobody knows" 0 "[]" -- bash "$p" list --json nosuch
check "list rejects an unknown option" 1 "Usage:" -- bash "$p" list --bogus

if FAKE_GH_FAIL=1 bash "$p" list --json worm | grep -qF '"runners":null'; then
  echo "ok   list --json reports runners null when GitHub can't be asked"
else
  echo "FAIL list --json reports runners null when GitHub can't be asked"
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
