#!/usr/bin/env bash
# Finds every repo under <owner> that has opted in to a local runner pool by
# carrying a .local_runner file at its root, and brings each one up.
#
# This is the alternative to pools.conf: opting in lives with the repo
# instead of a line in this host's own config, so it travels with a clone to
# a different host and does not require editing anything here every time a
# new repo is onboarded. pools.conf still exists and still works for a pool
# that should exist without the repo declaring it.
#
#   printf '' > .local_runner     # opt in, default count (2)
#   printf '3' > .local_runner    # opt in, want 3 runners
#
# Only private repos are ever brought up, no matter what the marker file
# says -- see README, "Private repositories only". A marker file on a public
# repo is not silently honoured; it is reported as a misconfiguration,
# because the alternative is a runner quietly waiting to execute a stranger's
# pull request.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

owner="${1:?usage: ./discoverPools.sh <owner>}"

check_marker() {
  # Prints the file's content on stdout if it exists; exits nonzero (silently) if not.
  gh api "repos/${owner}/${1}/contents/.local_runner" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null
}

# gh's own --jq (it bundles jq) does the filtering, so this needs no jq on
# the host running it -- only two repo-list calls rather than one, since a
# local shell variable can't be re-filtered without a local jq binary.
public_repos="$(gh repo list "$owner" --limit 400 --json name,visibility,isArchived   --jq '.[] | select(.isArchived==false and .visibility=="PUBLIC") | .name')"
private_repos="$(gh repo list "$owner" --limit 400 --json name,visibility,isArchived   --jq '.[] | select(.isArchived==false and .visibility=="PRIVATE") | .name')"

echo "$public_repos" |
while read -r repo; do
  [[ -z "$repo" ]] && continue
  if content="$(check_marker "$repo")"; then
    echo "!! ${owner}/${repo} is PUBLIC and carries .local_runner -- refusing to provision a pool for it." >&2
    echo "   Remove the file, or make the repo private, before this will be honoured." >&2
  fi
done

echo "$private_repos" |
while read -r repo; do
  [[ -z "$repo" ]] && continue
  content="$(check_marker "$repo")" || continue
  count="$(printf '%s' "$content" | tr -d '[:space:]')"
  [[ "$count" =~ ^[0-9]+$ ]] || count=2
  echo "== ${repo} (x${count}) =="
  ./pools.sh up "$repo" "${owner}/${repo}" "$count"
done

echo
./pools.sh list
