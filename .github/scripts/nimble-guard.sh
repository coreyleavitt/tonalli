#!/usr/bin/env bash

# nimble's exit code does not reflect nimble-script failures: a task
# that raises, calls quit(1), or fails an assert still exits 0 (nimble
# v0.22.2, reproduced for every failure kind). Every CI step that runs
# nimble therefore judges the log for nimble's script-failure banner in
# addition to the exit code. Usage: nimble-guard.sh <command> [args...]

set -uo pipefail

log=$(mktemp)
trap 'rm -f "$log"' EXIT

"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}

if grep -qE 'Error:[[:space:]]+Exception raised during nimble script execution' "$log"; then
  echo "nimble-guard: nimble reported a script failure its exit code (rc=$rc) did not carry" >&2
  exit 1
fi
exit "$rc"
