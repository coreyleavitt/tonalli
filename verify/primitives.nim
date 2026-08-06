## RFC 0001 D9-V / S9 — index primitives under verification.
##
## **FORK-ONLY. Never imported by, referenced by, or coupled to any
## upstream-bound file.** See `verify/README.md`.
##
## Textually mirrored, byte-for-byte, from the validated S9.0 spike
## (`git show spike/s9.0-callbackqueue:chronos/internal/callbackqueue.nim`)
## -- the same five pure int/bool procs D9 specifies as "index primitives,
## factored for verification". Zero marker coupling: these are the exact
## shapes the real `chronos/internal/callbackqueue.nim` will carry at S10,
## down to the assert messages, so a symex proof against this file is a
## symex proof against the shipped code (mechanically diffable at S10 to
## confirm no drift crept in between S9 and S10).
##
## Deliberately duplicated rather than imported: at S9 time,
## `chronos/internal/callbackqueue.nim` does not exist yet (D9 is
## implemented at S10, gated on this slice's findings) -- there is nothing
## in `chronos/` to import from. `verify/` importing FROM `chronos/` (e.g.
## `chronos/config` for the sink templates, used by `callbackqueue_model.nim`)
## is fine per D9-V's segregation rule; the forbidden direction is
## `chronos/` importing `verify/`.
##
## **One deliberate deviation from the spike, and a finding for S10 (see
## `verify/README.md`'s ledger):** the spike declared these five as `func`;
## here they are `proc {.noSideEffect.}` (identical codegen -- `func` is
## pure sugar for that exact pragma). This is not cosmetic: proptest's
## symex Phase-3 interprocedural resolution (`ensureProcRegistered`,
## `dsl_parser.nim`) hard-errors on any callee whose `getImpl.kind !=
## nnkProcDef` -- `func` lowers to `nnkFuncDef` and is REJECTED outright,
## both as a direct `symexFind` target and as a callee reached from one
## (verified empirically: `symex Phase 3: cannot resolve getImpl for
## callee 'capMask' -- generic / private cross-module / built-in?`).
## D9's own RFC prose already specifies "pure int->int/bool procs" (not
## funcs) for exactly this reason; the throwaway S9.0 spike's `func` choice
## is spike-only shorthand the S9.0 disposal rule already marks as not the
## S10 deliverable. Recorded here so S10 does not silently reintroduce
## `func` and quietly lose future symex-walkability.
##
## **A second finding, this one in the verification tool itself (recorded
## in `verify/README.md`'s ledger as a proptest/symex issue, not a D9
## defect):** two related shapes crash the symex walker outright
## (`AssertionDefect ... lowerBool: expected Bool, got svBV64`,
## `runtime.nim:3345`), both isolated empirically to minimal repros:
##
##   1. `doAssert (cap and (cap - 1)) == 0` -- a bitwise-`and` whose
##      second operand is an INLINE arithmetic sub-expression of the SAME
##      variable as the first operand. Fixed by binding the subtraction to
##      a named `let` first (`capMask`, below).
##   2. `pos and capMask(cap)` / `queueLen(head, tail) >= cap` -- a
##      boolean-or-bitwise expression with a DIRECT (non-let-bound)
##      function-call result as one operand (interprocedural depth 2:
##      the caller of `slotIndex`/`isFull` calling INTO them, which then
##      call `capMask`/`queueLen` inline within their own return
##      expression). Fixed the same way: bind the call's result to a
##      named `let` before using it (`slotIndex`, `isFull`, below).
##
## Both are semantically no-ops (identical codegen once optimized; still a
## single expression at the source level in any reasonable reading) and
## both are walker limitations, not D9 soundness questions -- the shipped
## S10 code is free to keep the spike's exact expression-bodied shapes;
## only the symex-walked mirror here needs the hoists to be provable at
## all. Filing this as a limitation against proptest itself is out of this
## slice's scope; the workaround is cheap, mechanical, and self-contained.

proc capMask*(cap: int): int {.inline, noSideEffect.} =
  let capMinusOne = cap - 1
  doAssert cap > 0 and (cap and capMinusOne) == 0,
    "CallbackQueue: capacity must be a positive power of two"
  capMinusOne

proc slotIndex*(pos, cap: int): int {.inline, noSideEffect.} =
  ## Fold a monotonic logical position into `[0, cap)`. `cap` being a
  ## power of two makes this correct for negative `pos` too (two's
  ## complement `and` is congruent mod `cap`), which `addFirst`'s
  ## `dec head` relies on.
  let mask = capMask(cap)
  pos and mask

proc queueLen*(head, tail: int): int {.inline, noSideEffect.} =
  doAssert tail >= head, "CallbackQueue: tail must never precede head"
  tail - head

proc isFull*(head, tail, cap: int): bool {.inline, noSideEffect.} =
  let n = queueLen(head, tail)
  n >= cap

proc growTargetCap*(cap: int): int {.inline, noSideEffect.} =
  doAssert cap >= 0, "CallbackQueue: capacity must not be negative"
  if cap == 0: 8 else: cap * 2
