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
## (sink), `prependNoGrow` (sink; sole caller is sentinel re-insertion in
## `asyncengine.nim`'s `poll()`), `popFirst` (a `template` — see below),
## `len`.

{.push raises: [], gcsafe.}

import ../config

type
  CallbackQueue*[T] = object
    ## Seq-backed queue with monotonic logical `head`/`tail` positions
    ## held as `uint`: rather than ever raising an overflow error after
    ## enough pushes/pops over a long-running dispatcher's lifetime,
    ## `head`/`tail` wrap around at `high(uint) + 1` - well-defined,
    ## unchecked `uint` arithmetic, textbook ring-buffer discipline.
    ## `head == tail` is unambiguously "empty" whether or not either has
    ## wrapped: unsigned subtraction (`tail - head`) is congruent modulo
    ## `2^wordsize`, so it recovers the true logical length regardless of
    ## how many times either has wrapped, as long as that length never
    ## exceeds `cap` - an invariant `isFull` itself asserts on every
    ## check. Logical positions are folded into the physical `[0, cap)`
    ## range only at slot access (`slotIndex`), never by clamping
    ## `head`/`tail` themselves.
    ##
    ## The zero value (`CallbackQueue[T]()`, no `initCallbackQueue` call)
    ## is a valid, empty queue that lazily grows from capacity `0` on the
    ## first `addLast`, matching `std/deques`' own lazy-init behavior.
    ## `asyncengine.nim`'s POSIX `Dispatcher.ticks` field relies on this.
    data: seq[T]
    head: uint
    tail: uint

# --- index primitives ---------------------------------------------------

proc capMask(cap: int): uint {.inline.} =
  # `capMinusOne` is bound to a `let` rather than inlined directly into
  # the `and` below - same expression either way (identical codegen),
  # but `verify/`'s symex walker (fork-only, see `verify/primitives.nim`)
  # cannot resolve a bitwise-`and` whose second operand is an inline
  # arithmetic sub-expression of the same variable as the first operand.
  let capMinusOne = cap - 1
  doAssert cap > 0 and (cap and capMinusOne) == 0,
    "CallbackQueue: capacity must be a positive power of two"
  uint(capMinusOne)

proc slotIndex(pos: uint, cap: int): int {.inline.} =
  ## Fold a monotonic (uint, possibly-wrapped) logical position into
  ## `[0, cap)`. `cap` being a power of two makes this correct across a
  ## `pos` wrap too (unsigned `and` is congruent mod `cap`), which
  ## `prependNoGrow`'s `dec head` relies on when `head == 0`.
  ##
  ## `mask` is bound to a `let` for the same symex-walkability reason as
  ## `capMask` above (a direct, non-let-bound call result as an `and`
  ## operand is the walker's other documented blind spot).
  let mask = capMask(cap)
  int(pos and mask)

proc queueLen(head, tail: uint): int {.inline.} =
  ## `tail - head`, unsigned: congruent mod `2^wordsize`, so this is the
  ## true logical length whether or not `head`/`tail` have wrapped - no
  ## ordering comparison between them is meaningful any more (unlike the
  ## former monotonic-`int` discipline, "tail must never precede head"
  ## does not hold under wraparound).
  int(tail - head)

proc isFull(head, tail: uint, cap: int): bool {.inline.} =
  let n = queueLen(head, tail)
  doAssert n >= 0 and n <= cap,
    "CallbackQueue: length invariant violated - `tail - head` " &
    "(mod 2^wordsize) must never exceed capacity"
  n >= cap

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
  CallbackQueue[T](data: newSeq[T](cap), head: 0'u, tail: 0'u)

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
  q.head = 0'u
  q.tail = uint(n)

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

proc prependNoGrow*[T](q: var CallbackQueue[T], item: chronosSink T) =
  ## Push onto the front. Precondition: `q` must not be full — unlike
  ## `addLast`, there is no growth path here, so the caller must never
  ## invoke this on a full queue. Not a general push-front primitive;
  ## intended for re-inserting an item into a queue known to have
  ## spare capacity (e.g. re-inserting a sentinel at the front of an
  ## already-fully-drained batch).
  doAssert not isFull(q.head, q.tail, q.data.len),
    "CallbackQueue.prependNoGrow(): queue unexpectedly full"
  dec q.head
  let idx = slotIndex(q.head, q.data.len)
  q.data[idx] = item

when defined(chronosDebug):
  proc chronosCheckVacatedSlot[T](item: T) {.inline.} =
    ## Debug-only guardrail: every slot `popFirst` vacates must end up
    ## default-valued, catching a slot-vacating path that bypasses the
    ## fused-move discipline below. A standalone generic `proc`, not
    ## inlined into `popFirst`'s `when defined(chronosDebug):` body: Nim
    ## 1.6 fails to resolve `default(T)`'s `T` as the template's generic
    ## parameter when the call sits inside a `when` block nested in a
    ## generic `template` (`Error: type mismatch: got <InternalAsyncCallback>`
    ## at the call to `default`, cross-checked against a known Nim
    ## generic-template-plus-`when` type-resolution bug of the same
    ## shape) - a `proc`'s own generic-instantiation path does not hit
    ## this, so hoisting the check here is the fix, not a workaround for
    ## a real ambiguity in what's being asserted.
    doAssert item == default(T),
      "CallbackQueue: a vacated slot retained a non-nil ghost value after " &
      "popFirst() — a slot-vacating path bypassed the fused-move discipline"

template popFirst*[T](q: var CallbackQueue[T]): T =
  ## Fused dequeue. A `template`, not a `proc`: a proc returning `T` by
  ## value pays refc's hidden-return-slot reset-then-assign lowering
  ## regardless of `{.inline.}`. Callers must consume the result directly
  ## in a `let` binding at the call site so the moved-out value lands in
  ## a fresh caller-frame local rather than through an intermediate hop.
  ##
  ## The vacated slot is cleared via `chronosMoveSink`, an lvalue read of
  ## a live queue slot — unlike `addLast`/`prependNoGrow` above, which assign
  ## already-spent `sink` parameters directly.
  doAssert q.tail != q.head, "CallbackQueue.popFirst(): queue is empty"
  let chronosQueueIdx = slotIndex(q.head, q.data.len)
  inc q.head
  when defined(chronosDebug):
    let chronosPopped = chronosMoveSink(q.data[chronosQueueIdx])
    chronosCheckVacatedSlot(q.data[chronosQueueIdx])
    chronosPopped
  else:
    chronosMoveSink(q.data[chronosQueueIdx])
