## RFC 0001 D9-V / S9 — Layer 1: symex proofs of the index primitives.
## Updated W3 for `head`/`tail`'s `int` -> `uint` wraparound-counter change.
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh symex`.
##
## Each `checkXxx` proc assumes exactly the precondition its primitive's own
## `doAssert` states (via `symexAssume`, never re-derived informally), calls
## the REAL primitive through `primitives.nim`'s thin exported `*V` wrappers
## (`primitives.nim` `include`s `chronos/internal/callbackqueue.nim` and
## re-exports each of the five index primitives under a `V`-suffixed name -
## see that file's module doc for why this file goes back to plain `import
## ./primitives` rather than a further `include`), and asserts the
## postcondition (via `symexAssert`). `symexFind(checkXxx,
## tAssertionViolation())` returning `sxUnsat` is a totality+safety PROOF: no
## input satisfying the assumed precondition reaches ANY assertion violation
## -- neither the checker's own postcondition assert nor the primitive's
## internal precondition assert (symex's interprocedural call handling walks
## through the wrapper into the real code, so both are on the same proved
## path - the wrapper is logic-free, so this proves the real primitive, not
## an approximation of it).
##
## Two named edges (RFC 0001 S9 exit criteria, restated for `uint`):
##   * `checkSlotIndexRange` assumes NOTHING about `pos` -- proved over the
##     FULL `uint` domain, which subsumes the `prependNoGrow` wraparound edge
##     (`dec head` at `head == 0` wraps to `high(uint)` rather than going
##     negative now; a general proof over all `pos` is strictly stronger than
##     a proof scoped to "one decrement below zero", exactly as the old
##     int-domain proof was).
##   * `checkGrowSweep` mirrors `callbackqueue_model.grow`'s two-segment index
##     arithmetic (`startIdx`, `firstSeg`, `rest`) and proves both segments
##     stay in bounds and jointly cover exactly `n` items once each -- the
##     wrapped-region growth sweep, at the index level (heap-slot relocation
##     soundness itself is out of symex's reach; that is `bmc_ghost.nim`'s
##     ghost-ownership job for the elements it can model, and the standing
##     runtime-verified claim in D9's prose for the rest).
##
## **W3's bounds argument, replacing the pre-W3 ledger entries below:**
## under the OLD monotonic-`int` discipline, `checkQueueLen`/`checkIsFull`
## needed `head`/`tail` bounded to `[-2^40, 2^40]` because unconstrained
## `tail - head` genuinely overflowed `int` (Nim's checked signed
## arithmetic raises `OverflowDefect`) -- and `tail >= head` had to be
## assumed outright, an ordering relationship the design relied on holding
## forever (a latent long-run risk this whole W3 change exists to remove).
## Under the NEW `uint` discipline, unsigned subtraction is congruent mod
## `2^64` by definition -- it cannot overflow, and no ordering between
## `head`/`tail` is assumed at all (meaningless under wraparound; see
## `callbackqueue.nim`'s `queueLen` doc). The precondition that replaces
## `tail >= head` is the REAL invariant the design actually maintains --
## `isFull`'s own `doAssert`: the wrapped distance from `head` to `tail`
## never exceeds capacity. `checkQueueLen`/`checkIsFull` below assume
## exactly that (`(tail - head) <= uint(cap)`, unsigned compare) instead of
## an ordering relationship, and are proved over the FULL `uint` domain for
## `head`/`tail` -- no `2^40` bound needed on them at all; only `cap` still
## carries the `realisticCapBound` scope-out (no physical queue holds 2^40
## pending callbacks), same as `growTargetCap`'s multiplication.
##
## **A verification-tooling finding (recorded in the ledger, not a D9
## defect -- see `primitives.nim`'s module doc for the full isolation):**
## `symexAssume`/`symexAssert` of the inline shape
## `(cap and (cap - 1)) == 0` crashes the symex walker
## (`lowerBool: expected Bool, got svBV64`). `isPow2` below hoists the
## subtraction to a named local exactly as the real `capMask` now does,
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
  # No assumption on head/tail ordering, and no domain bound on head/tail
  # themselves - unsigned subtraction cannot overflow, so both are
  # unconstrained over the FULL `uint` domain. The precondition that
  # replaces "tail >= head" is the invariant the design actually
  # maintains: the wrapped distance from `head` to `tail` never exceeds
  # capacity (this is `isFull`'s own `doAssert`, restated here as an
  # assumption for `queueLen` alone). `cap` keeps the same
  # `realisticCapBound` scope-out as `growTargetCap` (no physical queue
  # ever holds 2^40 pending callbacks).
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

echo "=== D9-V Layer 1: symex proofs of the index primitives ==="

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
