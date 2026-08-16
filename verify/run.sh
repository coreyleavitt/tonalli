#!/bin/sh
# RFC 0001 D9-V / S9-S11 — fork-only verification harness runner.
#
# FORK-ONLY. Intended to run INSIDE the verify container (see README.md for
# the podman build/run invocation) with the working directory set to
# `verify/` and `/home/corey/projects/nim/libs` bind-mounted at its own
# absolute path (so nim.cfg's --path lines resolve identically in- and
# out-of-container).
#
# Usage: verify/run.sh <symex|bmc|drift|bisim|fuzz|all>
#
# `bisim` and `fuzz` (S11 layers 3-4) are MM-sensitive -- run once per MM,
# selected via the MM env var (default refc): `MM=orc ./run.sh bisim`.
# `symex`/`bmc`/`drift` are MM-independent (layers 1-2 never touch a real
# allocator or MM; drift is a pure text comparison) and always run under
# --mm:orc (arbitrary, matches S9's existing invocation).
#
# `HOME` must point at a nimble-populated home (`.docker-home` at the
# worktree root, NOT this directory's throwaway `.container-home`) for any
# invocation that also needs `unittest2` off the nimble path -- this
# script's own layers never need it, but S11's Layer 5 (mutation testing)
# runs `tests/testcallbackqueue.nim` directly (not through this script) as
# part of its kill-matrix legs, and that DOES need `unittest2`. See
# README.md's Layer 5 section for the exact invocations and the mutant
# patches under `verify/mutants/`.

set -eu

layer="${1:-all}"
mm="${MM:-refc}"

run_symex() {
  echo "--- Layer 1: symex proofs (verify/symex_checks.nim) ---"
  nim c -r --mm:orc --out:build/symex_checks symex_checks.nim
}

run_bmc() {
  echo "--- Layer 2: bmcCheck ghost-ownership model (verify/bmc_ghost.nim) ---"
  nim c -r --mm:orc --out:build/bmc_ghost bmc_ghost.nim
}

run_drift() {
  echo "--- Drift check: verify/ mirrors vs tonalli/internal/callbackqueue.nim ---"
  nim c -r --mm:orc --out:build/drift_check drift_check.nim
}

run_bisim() {
  echo "--- Layer 3: bisimulation vs std/deques reference (--mm:$mm) ---"
  nim c -r --mm:"$mm" --out:build/bisim_check_"$mm" bisim_check.nim
}

run_fuzz() {
  echo "--- Layer 4: coverage-guided fuzz + GC stress + leak accounting (--mm:$mm) ---"
  nim c -r --mm:"$mm" --out:build/fuzz_leak_"$mm" fuzz_leak.nim
}

case "$layer" in
  symex) run_symex ;;
  bmc)   run_bmc ;;
  drift) run_drift ;;
  bisim) run_bisim ;;
  fuzz)  run_fuzz ;;
  all)   run_symex; run_bmc; run_drift; run_bisim; run_fuzz ;;
  *)
    echo "usage: $0 <symex|bmc|drift|bisim|fuzz|all>" >&2
    exit 2
    ;;
esac
