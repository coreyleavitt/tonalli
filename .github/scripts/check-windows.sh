#!/usr/bin/env bash

# Mirrors tonalli.nimble's check_windows task: nim's own semantic check
# ("nim check") stands in for a Windows cross-compile, since the CI
# container has no mingw. Deliberately ignores NIMFLAGS, same as the
# nimble task.
set -euo pipefail

verbose=0
if [[ -n "${V:-}" && "${V:-}" != "0" ]]; then
  verbose=1
fi

cfg=(--styleCheck:usages --styleCheck:error)
if [[ "$verbose" -eq 0 ]]; then
  cfg+=(--verbosity:0 --hints:off)
fi
# $projectName below is nim's own substitution, not the shell's.
# shellcheck disable=SC2016
cfg+=(
  --skipParentCfg --skipUserCfg --outdir:build
  '--nimcache:build/nimcache/$projectName'
)

# --skipParentCfg keeps the repo-root nim.cfg (milpa's --path set) from
# reaching targets outside the root directory, so the deps go on the
# command line directly instead.
for dep in _deps/*/; do
  cfg+=("--path:${dep%/}")
done

wincfg=("${cfg[@]}" --os:windows -d:windows)
simdefines=(-d:chronosSimulation -d:tonalliFutureTracking --threads:on)

check() {
  echo "check_windows: $*"
  nim check "${wincfg[@]}" "$@"
}

check tonalli.nim
check "${simdefines[@]}" tonalli/simulation.nim

simLeafTests=(
  tests/testsimclock tests/testsimengine tests/testsimloop
  tests/testsimoracle tests/testsimtrace tests/testsimulation
  tests/testsimstream tests/testsimnet tests/testsimdatagram
  tests/testsimproducer tests/testsimledger tests/testsimhttp
  tests/testsimreplay
)
for t in "${simLeafTests[@]}"; do
  check "${simdefines[@]}" "$t.nim"
done

check "${simdefines[@]}" tests/testall.nim
