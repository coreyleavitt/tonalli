#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Move-based, seq-backed FIFO queue used for chronos's three dispatcher
## queues (`DispatcherBase.callbacks`/`idlers`/`ticks`, `chronos/internal/
## asyncengine.nim`), replacing `std/deques` there (RFC 0001 D9).
##
## `std/deques.popFirst` is a `proc` returning `T` by value: under `--mm:refc`
## this lowers to a hidden-return-slot reset-then-assign, paying three
## write-barrier calls per `ref` field of `T` (a dead zero-init of the
## return slot, the copy-out, and the slot-clear) where one is the floor —
## the same defect class construction paid before RFC 0001 D8's template
## discipline, on the dequeue side instead. `std/deques` cannot be fixed in
## place: the fix requires a `template`, which a stdlib proc API cannot
## become. `addLast` was already at its floor (one write-barrier call per
## `ref` field — refc cannot prove a reused, persistent slot's prior
## contents nil, and no queue design changes that); this module keeps that
## floor and fixes the dequeue side, halving `AsyncCallback`'s two-`ref`-field
## round-trip cost under refc for every chronos callback (8 barrier calls
## per enqueue+dequeue cycle down to 4 — RFC 0001 §2). `--mm:orc` is
## unaffected either way: its compositional ownership tracking already
## reaches this floor through `std/deques`.
##
## Interface is exactly five entry points — the grep-verified usage set,
## nothing else: `initCallbackQueue`, `addLast` (sink), `addFirst` (sink;
## sole caller is sentinel re-insertion in `asyncengine.nim`'s `poll()`),
## `popFirst` (a `template` — see below), `len`. No iteration, no `clear`,
## no peek: no caller needs them, and a narrower interface is a narrower
## place for a slot-vacating bug to hide.
##
## Styled on `chronos/internal/mpsc.nim` (`{.push raises: [], gcsafe.}`,
## terse doc comments, no ceremony). Validated in two independent rounds
## before this module existed: RFC 0001 S9.0 measured this exact shape's
## cross-commit timing at refc/orc parity with the pre-substrate base
## (`spike/s9.0-callbackqueue`, `ad569a3`); RFC 0001 S9's ghost-model BMC
## harness (`verify/`, fork-only, never upstreamed) exhaustively swept the
## index primitives and the fused-move ownership discipline below for
## refcount conservation and vacated-slot-zeroing. This module promotes
## that validated shape into the real implementation.

{.push raises: [], gcsafe.}

import ../config

type
  CallbackQueue*[T] = object
    ## Seq-backed queue with monotonic (never-wrapped) logical `head`/
    ## `tail` positions — `head == tail` is unambiguously "empty" no
    ## matter how many times the backing buffer has wrapped physically.
    ## Folding a logical position into the physical `[0, cap)` range
    ## happens only at slot access (`slotIndex`), never by clamping
    ## `head`/`tail` themselves. `data`/`head`/`tail` are private: every
    ## external touch goes through the five procs/templates below (pinned
    ## by a raw-access non-compile check in `tests/testcallbackqueue.nim`).
    ##
    ## The zero value (`CallbackQueue[T]()`, no `initCallbackQueue` call)
    ## is a valid, empty queue — `data` is an empty seq, so `len` is `0`
    ## and the first `addLast` lazily grows from capacity `0`. This
    ## property is deliberately preserved (not merely incidental) because
    ## `asyncengine.nim`'s POSIX `Dispatcher.ticks` field relies on it: it
    ## is never explicitly constructed in `newDispatcher()`, exactly as it
    ## relied on `std/deques`' own lazy-init behavior before this module
    ## existed. Pinned by a test.
    data: seq[T]
    head: int
    tail: int

# --- index primitives ---------------------------------------------------
#
# Factored out as plain int/bool arithmetic, each carrying an unconditional
# `doAssert` invariant (deliberately not `chronosDebug`-gated: negligible
# cost beside the refcount work this module exists to save, and it keeps
# the shipped code identical to what a fork verification harness walks —
# see RFC 0001 D9-V / S9, `verify/README.md`'s proof ledger). Declared as
# `proc`, never `func`: RFC 0001 S9 found that proptest's symex
# interprocedural resolution hard-rejects any callee lowering to
# `nnkFuncDef` (a real tool limitation, not a soundness question — `func`
# is pure sugar for `proc {.noSideEffect.}` and would codegen identically),
# so keeping these as `proc` is what lets S11's harness build-out walk this
# exact shipped module with zero marker coupling and zero source
# duplication.

proc capMask(cap: int): int {.inline.} =
  doAssert cap > 0 and (cap and (cap - 1)) == 0,
    "CallbackQueue: capacity must be a positive power of two"
  cap - 1

proc slotIndex(pos, cap: int): int {.inline.} =
  ## Fold a monotonic logical position into `[0, cap)`. `cap` being a
  ## power of two makes this correct for negative `pos` too (two's
  ## complement `and` is congruent mod `cap`), which `addFirst`'s
  ## `dec head` relies on.
  pos and capMask(cap)

proc queueLen(head, tail: int): int {.inline.} =
  doAssert tail >= head, "CallbackQueue: tail must never precede head"
  tail - head

proc isFull(head, tail, cap: int): bool {.inline.} =
  queueLen(head, tail) >= cap

proc growTargetCap(cap: int): int {.inline.} =
  doAssert cap >= 0, "CallbackQueue: capacity must not be negative"
  if cap == 0: 8 else: cap * 2

# --- public interface -----------------------------------------------------

proc initCallbackQueue*[T](initialCap: int = 8): CallbackQueue[T] =
  ## Construct a queue with capacity rounded up to the next power of two
  ## (`slotIndex`'s bitmask folding requires it). Not required before use —
  ## see the zero-value note on `CallbackQueue` above — but the dispatcher
  ## constructors call this to size the backing store up front and avoid
  ## early growth churn.
  var cap = 1
  while cap < initialCap:
    cap = cap * 2
  CallbackQueue[T](data: newSeq[T](cap), head: 0, tail: 0)

func len*[T](q: CallbackQueue[T]): int {.inline.} =
  queueLen(q.head, q.tail)

proc grow[T](q: var CallbackQueue[T]) =
  ## Whole-region relocation: one or two `copyMem` segments (two only when
  ## the live region is physically wrapped in the old backing — the split
  ## point falls straight out of `slotIndex`, no dedicated primitive
  ## needed) followed by a matching `zeroMem` of the vacated old region.
  ## The `zeroMem` is not cosmetic: `copyMem` does not touch the MM, so
  ## without it the old seq's eventual destructor would see the relocated
  ## `ref` fields as still-owned and decref them a second time — relocating
  ## an already-counted ref between GC-traced heap slots must neither
  ## create nor destroy a count. This is sound (empirically verified, both
  ## MMs, including a genuine wrapped-region grow — no premature free, no
  ## leak) and cheap: O(1) barrier calls, only the backing-seq handle
  ## reassignment (`q.data = newData`) crosses a write-barrier call site —
  ## the element relocation itself is raw memory movement, not per-slot
  ## assignment (a per-slot `move` loop was probed and rejected: O(N)
  ## barrier calls for no benefit over this strictly cheaper shape).
  let oldCap = q.data.len
  let n = queueLen(q.head, q.tail)
  doAssert n == oldCap, "CallbackQueue.grow(): called on a non-full queue"
  let newCap = growTargetCap(oldCap)
  var newData = newSeq[T](newCap)
  if n > 0:
    let startIdx = slotIndex(q.head, oldCap)
    let firstSeg = min(n, oldCap - startIdx)
    copyMem(addr newData[0], addr q.data[startIdx], firstSeg * sizeof(T))
    zeroMem(addr q.data[startIdx], firstSeg * sizeof(T))
    if firstSeg < n:
      let rest = n - firstSeg
      copyMem(addr newData[firstSeg], addr q.data[0], rest * sizeof(T))
      zeroMem(addr q.data[0], rest * sizeof(T))
  q.data = newData
  q.head = 0
  q.tail = n

proc addLast*[T](q: var CallbackQueue[T], item: chronosSink T) =
  if isFull(q.head, q.tail, q.data.len):
    grow(q)
  let idx = slotIndex(q.tail, q.data.len)
  # `item` is already `chronosSink T` (a `sink` parameter under
  # `chronosUseSink`) and used exactly once, here, at its last use —
  # assigned DIRECTLY so Nim's own sink-parameter move analysis does the
  # work, matching `std/deques`' own `addLast` shape exactly. Do not wrap
  # this in `chronosMoveSink`: RFC 0001 S9.0 measured that an explicit
  # `chronosMoveSink` around an already-sink parameter here is redundant
  # (refc's barrier *count* is unaffected, since the extra `nimZeroMem`
  # calls and field-by-field copy into an intermediate temp are not
  # barrier calls) but costs a real, measurable extra `eqwasMoved` call
  # plus an intermediate temp under orc — invisible to the refc-only
  # codegen spot-check, caught only by cross-commit timing. The rule this
  # generalizes to (stated for every future `chronosSink`-adjacent site,
  # per RFC 0001 §6 S10's binding S9.0 lesson): a `sink` parameter
  # consumed exactly once, at its last use, is assigned directly —
  # `chronosMoveSink` is for lvalues that are not themselves already a
  # spent `sink` parameter (see `popFirst` below, and the pre-existing
  # `futures.nim`/`asyncfutures.nim` call sites this mirrors).
  q.data[idx] = item
  inc q.tail

proc addFirst*[T](q: var CallbackQueue[T], item: chronosSink T) =
  ## Push onto the front. Sole caller: sentinel re-insertion at the front
  ## of an already-fully-drained batch (`asyncengine.nim`'s `poll()`,
  ## mirroring the pre-D9 `Deque.addFirst` call there). Never a general
  ## push-front, so there is no growth path here — the invariant a caller
  ## must never violate is enforced by the assert below rather than a
  ## silent grow-on-addFirst no caller should ever trigger.
  doAssert not isFull(q.head, q.tail, q.data.len),
    "CallbackQueue.addFirst(): queue unexpectedly full"
  dec q.head
  let idx = slotIndex(q.head, q.data.len)
  q.data[idx] = item

template popFirst*[T](q: var CallbackQueue[T]): T =
  ## Fused dequeue — the load-bearing shape (RFC 0001 D9). NEVER a `proc`,
  ## not even `{.inline.}`: a proc returning `T` by value pays refc's
  ## hidden-return-slot reset-then-assign lowering regardless of the
  ## inline pragma — the same defect class D8 fixed on the construction
  ## side, reproduced identically on the dequeue side (round-4 probe,
  ## confirmed again against the real generated C at S9.0). Callers MUST
  ## consume the result directly in a `let` binding at the call site
  ## (`let callable = q.popFirst()`, `processCallbacksBody`'s existing
  ## shape) so template expansion places the moved-out value straight into
  ## a fresh caller-frame local instead of through an intermediate hop —
  ## only expansion fused with same-frame consumption reaches the floor.
  ##
  ## The vacated slot's clear goes through `chronosMoveSink` (an lvalue
  ## read of a live queue slot, not an already-spent `sink` parameter —
  ## the opposite discipline from `addLast`/`addFirst` above, and for the
  ## same reason: the copy-out into the caller's fresh local elides to a
  ## bare store, and the one decref this pays per `ref` field is exactly
  ## the balance for `addLast`'s incref, not overhead — this is the floor,
  ## confirmed by the S9 ghost-model harness's refcount-conservation sweep
  ## against precisely this shape).
  doAssert q.tail > q.head, "CallbackQueue.popFirst(): queue is empty"
  let chronosQueueIdx = slotIndex(q.head, q.data.len)
  inc q.head
  when defined(chronosDebug):
    # Guardrail canary (RFC 0001 D9): the manual-discipline invariant that
    # no compiler check can enforce — every slot this queue ever vacates
    # goes through this one named primitive, and the vacated slot must
    # never retain a non-nil ghost reference afterward (the same class of
    # net RFC 0001 D0/D5/D8 close elsewhere for the context chain and
    # callback constructors). Gated behind `chronosDebug` — not part of
    # the fused shape above, so it costs nothing in release/refc-bellwether
    # builds and never perturbs the tier-1/tier-2 measurements: the `when`
    # is fully elided when undefined, leaving the exact single-expression
    # form the barrier-count analysis above describes.
    let chronosPopped = chronosMoveSink(q.data[chronosQueueIdx])
    doAssert q.data[chronosQueueIdx] == default(T),
      "CallbackQueue: a vacated slot retained a non-nil ghost value after " &
      "popFirst() — a slot-vacating path bypassed the fused-move discipline"
    chronosPopped
  else:
    chronosMoveSink(q.data[chronosQueueIdx])
