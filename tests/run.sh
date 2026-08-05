#!/usr/bin/env sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
for test in tests/core.lua tests/operations.lua tests/api.lua tests/progress.lua tests/sandbox.lua; do
  data=$(mktemp -d)
  state=$(mktemp -d)
  trap 'rm -rf "$data" "$state"' EXIT HUP INT TERM
  XDG_DATA_HOME="$data" XDG_STATE_HOME="$state" \
    nvim --headless -u NONE -i NONE -l "$root/$test"
  rm -rf "$data" "$state"
  trap - EXIT HUP INT TERM
done
