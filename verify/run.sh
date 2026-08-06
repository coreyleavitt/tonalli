#!/bin/sh
# RFC 0001 D9-V / S9 — fork-only verification harness runner.
#
# FORK-ONLY. Intended to run INSIDE the verify container (see README.md for
# the podman build/run invocation) with the working directory set to
# `verify/` and `/home/corey/projects/nim/libs` bind-mounted at its own
# absolute path (so nim.cfg's --path lines resolve identically in- and
# out-of-container).
#
# Usage: verify/run.sh <symex|bmc|all>

set -eu

layer="${1:-all}"

run_symex() {
  echo "--- Layer 1: symex proofs (verify/symex_checks.nim) ---"
  nim c -r --mm:orc --out:build/symex_checks symex_checks.nim
}

run_bmc() {
  echo "--- Layer 2: bmcCheck ghost-ownership model (verify/bmc_ghost.nim) ---"
  nim c -r --mm:orc --out:build/bmc_ghost bmc_ghost.nim
}

case "$layer" in
  symex) run_symex ;;
  bmc)   run_bmc ;;
  all)   run_symex; run_bmc ;;
  *)
    echo "usage: $0 <symex|bmc|all>" >&2
    exit 2
    ;;
esac
