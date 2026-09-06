#!/usr/bin/env bash
# Tears down every pool listed in pools.conf. Each container deregisters
# itself on the way out (see README, "Teardown") -- this is not a kill.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

conf="pools.conf"
[[ -f "$conf" ]] || { echo "no $conf -- cp pools.conf.example $conf and edit it" >&2; exit 1; }

while read -r name _ _ || [[ -n ${name:-} ]]; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  echo "== $name =="
  ./pools.sh down "$name"
done < <(tr -d '\r' < "$conf")
