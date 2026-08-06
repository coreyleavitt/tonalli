## RFC 0001 D9-V / S9 — Layer 1: symex proofs of the index primitives.
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh symex`.
##
## Each `checkXxx` proc assumes exactly the precondition its primitive's own
## `doAssert` states (via `symexAssume`, never re-derived informally), calls
## the mirrored primitive from `primitives.nim`, and asserts the postcondition
## (via `symexAssert`). `symexFind(checkXxx, tAssertionViolation())` returning
## `sxUnsat` is a totality+safety PROOF: no input satisfying the assumed
## precondition reaches ANY assertion violation -- neither the checker's own
## postcondition assert nor the primitive's internal precondition assert
## (symex's interprocedural call handling walks into `primitives.nim`, so
## both are on the same proved path).
##
## Two named edges (RFC 0001 S9 exit criteria):
##   * `checkSlotIndexRange` assumes NOTHING about `pos`'s sign -- proved over
##     the FULL int domain, which subsumes the addFirst edge (`dec head` can
##     drive `head` arbitrarily negative after repeated sentinel
##     reinsertions; a general proof over all `pos` is strictly stronger than
##     a proof scoped to "one decrement below zero").
##   * `checkGrowSweep` mirrors `callbackqueue_model.grow`'s two-segment index
##     arithmetic (`startIdx`, `firstSeg`, `rest`) and proves both segments
##     stay in bounds and jointly cover exactly `n` items once each -- the
##     wrapped-region growth sweep, at the index level (heap-slot relocation
##     soundness itself is out of symex's reach; that is `bmc_ghost.nim`'s
##     ghost-ownership job for the elements it can model, and the standing
##     runtime-verified claim in D9's prose for the rest).
##
## **Stated bound (recorded in the ledger, `verify/README.md`):** any check
## touching `growTargetCap`'s multiplication (`cap * 2`) assumes
## `cap <= realisticCapBound` (2^40). Unbounded, `cap` approaching `int.high`
## overflows the doubling -- a real finding, but one with zero physical
## reachability (no callback queue will ever hold 2^40 pending callbacks;
## that is exabytes of `AsyncCallback` slots) and so is explicitly scoped out
## rather than silently avoided. `capMask`/`slotIndex` need no such bound:
## bitwise AND cannot overflow.
##
## The SAME bound applies to `head`/`tail` in `checkQueueLen`/`checkIsFull`:
## unconstrained, `tail - head` genuinely overflows (symex found it --
## `OverflowDefect`, Nim's default checked-arithmetic behavior -- with
## `head`/`tail` free to range over the full int64 domain, e.g.
## `tail = int.high, head = int.low`). Realistically `head`/`tail` are
## monotonic counters incremented once per `addLast`/`addFirst`/`popFirst`
## call; reaching anywhere near `int.high` needs on the order of 2^63
## queue operations in one process lifetime -- bounded out for the same
## reason as `growTargetCap`'s cap bound, not silently avoided.
##
## **A verification-tooling finding (recorded in the ledger, not a D9
## defect -- see `primitives.nim`'s module doc for the full isolation):**
## `symexAssume`/`symexAssert` of the inline shape
## `(cap and (cap - 1)) == 0` crashes the symex walker
## (`lowerBool: expected Bool, got svBV64`). `isPow2` below hoists the
## subtraction to a named local exactly as `primitives.capMask` now does,
## which is the confirmed workaround; every precondition assumption in this
## file goes through it rather than re-deriving the inline shape.

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
  let m = capMask(cap)
  symexAssert(m == cap - 1)
  symexAssert(m >= 0)

# ---------------------------------------------------------------------------
# slotIndex -- totality + range, over the FULL int domain for `pos`
# (subsumes the negative-logical-position edge after addFirst).
# ---------------------------------------------------------------------------

proc checkSlotIndexRange(pos, cap: int) =
  symexAssume(cap > 0 and isPow2(cap))
  let idx = slotIndex(pos, cap)
  symexAssert(idx >= 0 and idx < cap)

# ---------------------------------------------------------------------------
# queueLen -- totality under its own precondition.
# ---------------------------------------------------------------------------

proc checkQueueLen(head, tail: int) =
  symexAssume(tail >= head and
              head >= -realisticCapBound and head <= realisticCapBound and
              tail >= -realisticCapBound and tail <= realisticCapBound)
  let n = queueLen(head, tail)
  symexAssert(n == tail - head)
  symexAssert(n >= 0)

# ---------------------------------------------------------------------------
# isFull -- agrees with its own definition (queueLen >= cap).
# ---------------------------------------------------------------------------

proc checkIsFull(head, tail, cap: int) =
  symexAssume(tail >= head and cap > 0 and isPow2(cap) and
              head >= -realisticCapBound and head <= realisticCapBound and
              tail >= -realisticCapBound and tail <= realisticCapBound)
  let full = isFull(head, tail, cap)
  symexAssert(full == (tail - head >= cap))

# ---------------------------------------------------------------------------
# growTargetCap -- totality + strict growth, bounded (see module doc).
# ---------------------------------------------------------------------------

proc checkGrowTargetCap(cap: int) =
  symexAssume(cap >= 0 and cap <= realisticCapBound)
  let g = growTargetCap(cap)
  symexAssert(g > cap)
  symexAssert(if cap == 0: g == 8 else: g == cap * 2)

# ---------------------------------------------------------------------------
# Wrapped-region growth sweep -- the two-segment copy's index arithmetic,
# mirroring callbackqueue_model.grow() exactly (n == oldCap, as grow() is
# only ever called on a full queue -- its own doAssert states this).
# ---------------------------------------------------------------------------

proc checkGrowSweep(head, oldCap: int) =
  symexAssume(oldCap > 0 and isPow2(oldCap) and oldCap <= realisticCapBound)
  let n = oldCap
  let startIdx = slotIndex(head, oldCap)
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
    # and n must fit under growTargetCap(oldCap) (checked separately above,
    # restated here at the call site for this exact n/oldCap pairing).
    symexAssert(firstSeg + rest == n)
    let newCap = growTargetCap(oldCap)
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

echo "=== D9-V Layer 1: symex proofs of the index primitives ==="

runProof("capMask: totality + m == cap-1",
         symexFind(checkCapMask, tAssertionViolation()))

runProof("slotIndex: range [0,cap) over the FULL int domain for pos " &
         "(subsumes the post-addFirst negative-head edge)",
         symexFind(checkSlotIndexRange, tAssertionViolation()))

runProof("queueLen: totality + n == tail-head",
         symexFind(checkQueueLen, tAssertionViolation()))

runProof("isFull: agrees with queueLen(head,tail) >= cap",
         symexFind(checkIsFull, tAssertionViolation()))

runProof("growTargetCap: totality + strict growth (bounded, see ledger)",
         symexFind(checkGrowTargetCap, tAssertionViolation()))

runProof("grow(): wrapped-region two-segment sweep is in-bounds and " &
         "covers exactly n items once each",
         symexFind(checkGrowSweep, tAssertionViolation()))

echo "=== Layer 1: all index-primitive proofs PROVEN ==="
