#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Move-based, seq-backed FIFO queue used for chronos's dispatcher queues
## (`DispatcherBase.callbacks`/`idlers`/`ticks`), replacing `std/deques`
## there.
##
## `std/deques.popFirst` returns `T` by value: under `--mm:refc` this
## lowers to a hidden-return-slot reset-then-assign, paying three
## write-barrier calls per `ref` field of `T` instead of one. `std/deques`
## cannot be fixed in place, since the fix requires a `template` and a
## stdlib proc API cannot become one. `--mm:orc` is unaffected either way.
##
## Interface is exactly five entry points: `initCallbackQueue`, `addLast`
## (sink), `addFirst` (sink; sole caller is sentinel re-insertion in
## `asyncengine.nim`'s `poll()`), `popFirst` (a `template` — see below),
## `len`.

{.push raises: [], gcsafe.}

import ../config

type
  CallbackQueue*[T] = object
    ## Seq-backed queue with monotonic (never-wrapped) logical `head`/
    ## `tail` positions — `head == tail` is unambiguously "empty" no
    ## matter how many times the backing buffer has wrapped physically.
    ## Logical positions are folded into the physical `[0, cap)` range
    ## only at slot access (`slotIndex`), never by clamping `head`/`tail`
    ## themselves.
    ##
    ## The zero value (`CallbackQueue[T]()`, no `initCallbackQueue` call)
    ## is a valid, empty queue that lazily grows from capacity `0` on the
    ## first `addLast`, matching `std/deques`' own lazy-init behavior.
    ## `asyncengine.nim`'s POSIX `Dispatcher.ticks` field relies on this.
    data: seq[T]
    head: int
    tail: int

# --- index primitives ---------------------------------------------------

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
  ## see the zero-value note on `CallbackQueue` above — but dispatcher
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
  ## the live region is physically wrapped in the old backing) followed by
  ## a matching `zeroMem` of the vacated old region. The `zeroMem` is not
  ## cosmetic: `copyMem` does not touch the MM, so without it the old
  ## seq's eventual destructor would see the relocated `ref` fields as
  ## still-owned and decref them a second time — relocating an
  ## already-counted ref between GC-traced heap slots must neither create
  ## nor destroy a count.
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
  # `item` is a spent `sink` parameter used exactly once, here — assign
  # directly so Nim's own move analysis applies. Do not wrap this in
  # `chronosMoveSink`, which is for lvalue reads (see `popFirst` below),
  # not already-sink parameters.
  q.data[idx] = item
  inc q.tail

proc addFirst*[T](q: var CallbackQueue[T], item: chronosSink T) =
  ## Push onto the front. Sole caller is sentinel re-insertion at the
  ## front of an already-fully-drained batch (`asyncengine.nim`'s
  ## `poll()`). Never a general push-front, so there is no growth path
  ## here: the caller must never call this on a full queue.
  doAssert not isFull(q.head, q.tail, q.data.len),
    "CallbackQueue.addFirst(): queue unexpectedly full"
  dec q.head
  let idx = slotIndex(q.head, q.data.len)
  q.data[idx] = item

template popFirst*[T](q: var CallbackQueue[T]): T =
  ## Fused dequeue. A `template`, not a `proc`: a proc returning `T` by
  ## value pays refc's hidden-return-slot reset-then-assign lowering
  ## regardless of `{.inline.}`. Callers must consume the result directly
  ## in a `let` binding at the call site so the moved-out value lands in
  ## a fresh caller-frame local rather than through an intermediate hop.
  ##
  ## The vacated slot is cleared via `chronosMoveSink`, an lvalue read of
  ## a live queue slot — unlike `addLast`/`addFirst` above, which assign
  ## already-spent `sink` parameters directly.
  doAssert q.tail > q.head, "CallbackQueue.popFirst(): queue is empty"
  let chronosQueueIdx = slotIndex(q.head, q.data.len)
  inc q.head
  when defined(chronosDebug):
    # Debug-only guardrail: every slot this queue vacates must end up
    # default-valued, catching a slot-vacating path that bypasses the
    # fused-move discipline above.
    let chronosPopped = chronosMoveSink(q.data[chronosQueueIdx])
    doAssert q.data[chronosQueueIdx] == default(T),
      "CallbackQueue: a vacated slot retained a non-nil ghost value after " &
      "popFirst() — a slot-vacating path bypassed the fused-move discipline"
    chronosPopped
  else:
    chronosMoveSink(q.data[chronosQueueIdx])
