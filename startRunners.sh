#!/usr/bin/env bash
# Brings up every pool listed in pools.conf. No arguments: "all of them" is
# defined by that file, not by what happens to be passed on the command line.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

conf="pools.conf"
[[ -f "$conf" ]] || { echo "no $conf -- cp pools.conf.example $conf and edit it" >&2; exit 1; }

while read -r name repo count || [[ -n ${name:-} ]]; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  echo "== $name ($repo, x$count) =="
  ./pools.sh up "$name" "$repo" "$count"
done < <(tr -d '\r' < "$conf")

echo
./pools.sh list
