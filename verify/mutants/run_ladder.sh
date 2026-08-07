#!/bin/sh
# Kill-ladder driver for Phase 2 (B-wave systematic mutant sweep).
# Not part of the tracked harness surface long-term -- ad hoc tool used to
# produce the kill matrix in verify/README.md. Run INSIDE the verify
# container, cwd = worktree root.
#
# Usage: run_ladder.sh <mutant_name_without_.patch> [mutant_name...]
#
# For each mutant: apply -> leg A -> leg B -> leg C -> leg D (stop at first
# kill) -> ALWAYS revert. Appends one line per mutant to
# verify/mutants/ladder_results.tsv: mutant<TAB>killed_by<TAB>notes

set -u
F=chronos/internal/callbackqueue.nim
RESULTS=verify/mutants/ladder_results.tsv

run_leg_a() {
  nim c -r -d:release --mm:refc --skipParentCfg --skipUserCfg --nimcache:build/nimcache_lad_a --out:build/leg_a tests/testcallbackqueue.nim > build/leg_a.log 2>&1
  echo $?
}

run_leg_b() {
  nim c -r -d:debug -d:chronosDebug -d:useSysAssert -d:useGcAssert --mm:refc --skipParentCfg --skipUserCfg --nimcache:build/nimcache_lad_b --out:build/leg_b tests/testcallbackqueue.nim > build/leg_b.log 2>&1
  echo $?
}

run_leg_c() {
  ( cd verify && nim c -r --mm:refc --nimcache:../build/nimcache_lad_c --out:../build/leg_c bisim_check.nim ) > build/leg_c.log 2>&1
  echo $?
}

run_leg_d() {
  ( cd verify && nim c -r --mm:refc --nimcache:../build/nimcache_lad_d --out:../build/leg_d fuzz_leak.nim ) > build/leg_d.log 2>&1
  echo $?
}

for name in "$@"; do
  patch="verify/mutants/${name}.patch"
  if [ ! -f "$patch" ]; then
    echo "MISSING PATCH: $patch" >&2
    continue
  fi
  echo "=== mutant: $name ==="
  git checkout -- "$F"
  if ! git apply "$patch"; then
    echo "  APPLY FAILED"
    printf "%s\tAPPLY_FAILED\t-\n" "$name" >> "$RESULTS"
    continue
  fi

  killed_by=""
  notes=""

  echo "  leg A (plain, -d:release --mm:refc)..."
  rc=$(run_leg_a)
  if [ "$rc" != "0" ]; then
    killed_by="A"
    notes="exit=$rc"
  else
    echo "  leg A survived; leg B (debug, chronosDebug)..."
    rc=$(run_leg_b)
    if [ "$rc" != "0" ]; then
      killed_by="B"
      notes="exit=$rc"
    else
      echo "  leg B survived; leg C (bisim, refc)..."
      rc=$(run_leg_c)
      if [ "$rc" != "0" ]; then
        killed_by="C"
        notes="exit=$rc"
      else
        echo "  leg C survived; leg D (fuzz, refc)..."
        rc=$(run_leg_d)
        if [ "$rc" != "0" ]; then
          killed_by="D"
          notes="exit=$rc"
        else
          killed_by="SURVIVOR"
          notes="all 4 legs passed"
        fi
      fi
    fi
  fi

  echo "  RESULT: $name killed_by=$killed_by ($notes)"
  printf "%s\t%s\t%s\n" "$name" "$killed_by" "$notes" >> "$RESULTS"

  git checkout -- "$F"
done

echo "=== ladder run complete ==="
cat "$RESULTS"
