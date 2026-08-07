## Layer 1: symex proofs of the index primitives (`head`/`tail` are `uint`
## wraparound counters).
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh symex`.
##
## Each `checkXxx` proc assumes exactly the precondition its primitive's own
## `doAssert` states (via `symexAssume`, never re-derived informally), calls
## the REAL primitive through `primitives.nim`'s thin exported `*V` wrappers,
## and asserts the postcondition (via `symexAssert`). `symexFind(checkXxx,
## tAssertionViolation())` returning `sxUnsat` is a totality+safety PROOF: no
## input satisfying the assumed precondition reaches ANY assertion violation
## -- neither the checker's own postcondition assert nor the primitive's
## internal precondition assert (symex's interprocedural call handling walks
## through the wrapper into the real code, so both are on the same proved
## path - the wrapper is logic-free, so this proves the real primitive, not
## an approximation of it).
##
## Two named edges:
##   * `checkSlotIndexRange` assumes NOTHING about `pos` -- proved over the
##     FULL `uint` domain, which subsumes the `prependNoGrow` wraparound edge
##     (`dec head` at `head == 0` wraps to `high(uint)` rather than going
##     negative).
##   * `checkGrowSweep` mirrors `callbackqueue_model.grow`'s two-segment index
##     arithmetic (`startIdx`, `firstSeg`, `rest`) and proves both segments
##     stay in bounds and jointly cover exactly `n` items once each -- the
##     wrapped-region growth sweep, at the index level (heap-slot relocation
##     soundness itself is out of symex's reach; that is `bmc_ghost.nim`'s
##     ghost-ownership job).
##
## **Bounds argument.** Unsigned subtraction is congruent mod `2^64` by
## definition, so it cannot overflow, and no ordering between `head`/`tail`
## is assumed at all (meaningless under wraparound; see `callbackqueue.nim`'s
## `queueLen` doc). The precondition is the REAL invariant the design
## actually maintains -- `isFull`'s own `doAssert`: the wrapped distance
## from `head` to `tail` never exceeds capacity. `checkQueueLen`/
## `checkIsFull` below assume exactly that (`(tail - head) <= uint(cap)`,
## unsigned compare), and are proved over the FULL `uint` domain for
## `head`/`tail` -- no bound needed on them at all; only `cap` carries the
## `realisticCapBound` scope-out (no physical queue holds 2^40 pending
## callbacks), same as `growTargetCap`'s multiplication.
##
## **A verification-tooling finding:** `symexAssume`/`symexAssert` of the
## inline shape `(cap and (cap - 1)) == 0` crashes the symex walker
## (`lowerBool: expected Bool, got svBV64`). `isPow2` below hoists the
## subtraction to a named local exactly as the real `capMask` does, which
## is the confirmed workaround; every precondition assumption in this file
## goes through it rather than re-deriving the inline shape.

import proptest/symex
import ./primitives

const realisticCapBound = 1 shl 40
  ## Stated, deliberate scope bound -- see module doc above.

proc isPow2(cap: int): bool {.inline, noSideEffect.} =
  ## `cap > 0` is checked separately by every call site -- this only
  ## tests the power-of-two bit pattern. See module doc: the walker
  ## crashes on the equivalent inline `(cap and (cap - 1)) == 0` shape;
  ## hoisting to `capMinusOne` first is the confirmed workaround.
  let capMinusOne = cap - 1
  (cap and capMinusOne) == 0

# ---------------------------------------------------------------------------
# capMask -- totality under its own precondition.
# ---------------------------------------------------------------------------

proc checkCapMask(cap: int) =
  symexAssume(cap > 0 and isPow2(cap))
  let m = capMaskV(cap)
  symexAssert(m == uint(cap - 1))
  # `m >= 0` (the old int-domain postcondition) is vacuously true for a
  # `uint` result - not silently dropped, just no longer a meaningful
  # thing to assert.

# ---------------------------------------------------------------------------
# slotIndex -- totality + range, over the FULL uint domain for `pos`
# (subsumes the post-wraparound-decrement edge in `prependNoGrow`).
# ---------------------------------------------------------------------------

proc checkSlotIndexRange(pos: uint, cap: int) =
  symexAssume(cap > 0 and isPow2(cap))
  let idx = slotIndexV(pos, cap)
  symexAssert(idx >= 0 and idx < cap)

# ---------------------------------------------------------------------------
# queueLen -- totality under the REAL invariant (`isFull`'s own), not an
# ordering relationship that is meaningless once `head`/`tail` can wrap.
# ---------------------------------------------------------------------------

proc checkQueueLen(head, tail: uint, cap: int) =
  # No assumption on head/tail ordering; unconstrained over the FULL
  # `uint` domain (see module doc's bounds argument).
  symexAssume(cap > 0 and cap <= realisticCapBound and
              (tail - head) <= uint(cap))
  let n = queueLenV(head, tail)
  symexAssert(n == int(tail - head))
  symexAssert(n >= 0 and n <= cap)

# ---------------------------------------------------------------------------
# isFull -- agrees with its own definition (wrapped distance >= cap).
# ---------------------------------------------------------------------------

proc checkIsFull(head, tail: uint, cap: int) =
  symexAssume(cap > 0 and isPow2(cap) and cap <= realisticCapBound and
              (tail - head) <= uint(cap))
  let full = isFullV(head, tail, cap)
  symexAssert(full == ((tail - head) >= uint(cap)))

# ---------------------------------------------------------------------------
# growTargetCap -- totality + strict growth, bounded (see module doc).
# ---------------------------------------------------------------------------

proc checkGrowTargetCap(cap: int) =
  symexAssume(cap >= 0 and cap <= realisticCapBound)
  let g = growTargetCapV(cap)
  symexAssert(g > cap)
  symexAssert(if cap == 0: g == 8 else: g == cap * 2)

# ---------------------------------------------------------------------------
# Wrapped-region growth sweep -- the two-segment copy's index arithmetic,
# mirroring callbackqueue_model.grow() exactly (n == oldCap, as grow() is
# only ever called on a full queue -- its own doAssert states this).
# ---------------------------------------------------------------------------

proc checkGrowSweep(head: uint, oldCap: int) =
  symexAssume(oldCap > 0 and isPow2(oldCap) and oldCap <= realisticCapBound)
  let n = oldCap
  let startIdx = slotIndexV(head, oldCap)
  let firstSeg = (if oldCap - startIdx < n: oldCap - startIdx else: n)

  # First segment: in-bounds read+write, non-empty (n > 0 since oldCap > 0).
  symexAssert(firstSeg >= 1 and firstSeg <= oldCap)
  symexAssert(startIdx >= 0 and startIdx < oldCap)
  symexAssert(startIdx + firstSeg <= oldCap)

  if firstSeg < n:
    let rest = n - firstSeg
    # Second segment reads old[0, rest) -- must stay within the old region.
    symexAssert(rest >= 1 and rest <= oldCap)
    # New array must hold both segments contiguously: firstSeg + rest == n,
    # and n must fit under growTargetCapV(oldCap) (checked separately above,
    # restated here at the call site for this exact n/oldCap pairing).
    symexAssert(firstSeg + rest == n)
    let newCap = growTargetCapV(oldCap)
    symexAssert(n <= newCap)
  else:
    # No wrap: the single segment already covers all n items.
    symexAssert(firstSeg == n)

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

proc runProof(name: string, r: SymexResult) =
  stdout.write "  " & name & " ... "
  case r.status
  of sxUnsat:
    echo "PROVEN (UNSAT: no reachable assertion violation)"
  of sxSat:
    echo "FALSIFIED -- witness: " & $r.witness
    doAssert false, name & ": symex found a counterexample (see witness above)"
  of sxUnknown:
    echo "UNKNOWN (solver could not decide within budget)"
    doAssert false, name & ": symex returned sxUnknown -- strengthen the bound or investigate"
  of sxRaised:
    echo "RAISED (unexpected non-assertion exception): " & $r.raisedTypeId
    doAssert false, name & ": symex found an unexpected raise path"

echo "=== Layer 1: symex proofs of the index primitives ==="

runProof("capMask: totality + m == cap-1",
         symexFind(checkCapMask, tAssertionViolation()))

runProof("slotIndex: range [0,cap) over the FULL uint domain for pos " &
         "(subsumes the post-prependNoGrow wraparound-head edge)",
         symexFind(checkSlotIndexRange, tAssertionViolation()))

runProof("queueLen: totality + n == tail-head",
         symexFind(checkQueueLen, tAssertionViolation()))

runProof("isFull: agrees with queueLenV(head,tail) >= cap",
         symexFind(checkIsFull, tAssertionViolation()))

runProof("growTargetCap: totality + strict growth (bounded, see ledger)",
         symexFind(checkGrowTargetCap, tAssertionViolation()))

runProof("grow(): wrapped-region two-segment sweep is in-bounds and " &
         "covers exactly n items once each",
         symexFind(checkGrowSweep, tAssertionViolation()))

echo "=== Layer 1: all index-primitive proofs PROVEN ==="
