## RFC 0001 D9-V / S9 — abstract `CallbackQueue[GhostItem]` model.
##
## **FORK-ONLY.** See `verify/README.md`.
##
## Mirrors D9's exact protocol (five entry points: `initCallbackQueue`,
## `addLast`, `addFirst`, `popFirst`, `len`; monotonic never-wrapped
## `head`/`tail`; whole-region `copyMem`+`zeroMem` growth; template-fused
## dequeue) against the same index primitives verified in `primitives.nim`.
## Field-for-field, op-for-op identical to the validated S9.0 spike
## (`spike/s9.0-callbackqueue`), generic over `T` exactly as D9 specifies.
##
## One deliberate addition beyond D9's real interface: `popFirstRejected`,
## a second dequeue template implementing the round-4 REJECTED shape
## (`copyMem` into a stack local, then `zeroMem` the vacated slot -- never
## routing the vacate through `chronosMoveSink`). D9 never ships this; it
## exists here only so the bmcCheck ghost-ownership model in `bmc_ghost.nim`
## has a second, structurally real (not hand-waved) implementation to
## falsify against the adopted `popFirst`. Both templates operate on the
## exact same private backing store.

import chronos/config  # verify/ -> chronos/ is the permitted direction.
import ./primitives

type
  GhostItem* = object
    ## The element type `bmc_ghost.nim` instantiates `CallbackQueue[T]`
    ## with. Deliberately a plain value (no ref field, no destructor): the
    ## refcount ledger the BMC model checks is EXTERNAL bookkeeping that
    ## mirrors what a real write-barrier/move/raw-memory-op would do to an
    ## actual GC-managed `AsyncCallback`, not something derived from
    ## Nim's own ARC/refc hooks (that comparison against the real
    ## allocator is layer 4's job, S11 -- see `bmc_ghost.nim`'s module
    ## doc). `id` is the ghost model's only handle: a unique tag identifying
    ## which captured item currently occupies a slot, letting the ledger
    ## track ownership per-id through `copyMem`/`zeroMem`/`chronosMoveSink`
    ## exactly as they operate on the real backing store.
    id*: int

  CallbackQueue*[T] = object
    ## Seq-backed queue with monotonic (never-wrapped) logical `head`/
    ## `tail` positions -- `head == tail` is unambiguously "empty" no
    ## matter how many times the backing buffer has wrapped physically.
    data: seq[T]
    head: int
    tail: int

proc initCallbackQueue*[T](initialCap: int = 8): CallbackQueue[T] =
  var cap = 1
  while cap < initialCap:
    cap = cap * 2
  CallbackQueue[T](data: newSeq[T](cap), head: 0, tail: 0)

func len*[T](q: CallbackQueue[T]): int {.inline.} =
  queueLen(q.head, q.tail)

func cap*[T](q: CallbackQueue[T]): int {.inline.} =
  q.data.len

func rawSlot*[T](q: CallbackQueue[T], physicalIdx: int): T {.inline.} =
  ## Test-only accessor: the raw backing slot by PHYSICAL index (not a
  ## logical position). Used by the bmcCheck model's
  ## "vacated-slot-zeroed" invariant, which must inspect storage the
  ## real D9 interface deliberately never exposes (no peek, no iteration
  ## -- per D9's stated interface scope).
  q.data[physicalIdx]

proc grow[T](q: var CallbackQueue[T]) =
  ## Whole-region relocation: one or two `copyMem` segments (two only
  ## when the live region is physically wrapped in the old backing)
  ## followed by a matching `zeroMem` of the vacated old region.
  ## Relocating an already-counted ref between GC-traced heap slots
  ## neither creates nor destroys a count -- ownership-neutral by
  ## construction (D9's stated growth argument; the index-level
  ## arithmetic is proved separately in `symex_checks.nim`).
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
  q.data[idx] = item
  inc q.tail

proc addFirst*[T](q: var CallbackQueue[T], item: chronosSink T) =
  ## Sole caller (D9): sentinel re-insertion at the front of an
  ## already-fully-drained batch -- never a general push-front, so no
  ## growth path here.
  doAssert not isFull(q.head, q.tail, q.data.len),
    "CallbackQueue.addFirst(): queue unexpectedly full"
  dec q.head
  let idx = slotIndex(q.head, q.data.len)
  q.data[idx] = item

template popFirst*[T](q: var CallbackQueue[T]): T =
  ## The ADOPTED shape (D9). Fused dequeue: the moved-out value lands
  ## straight in the caller-frame local; the vacated slot is cleared by
  ## `chronosMoveSink`'s own `wasMoved` semantics -- one transfer, same
  ## step, no intermediate uncounted hop.
  doAssert q.tail > q.head, "CallbackQueue.popFirst(): queue is empty"
  let chronosQueueIdx = slotIndex(q.head, q.data.len)
  inc q.head
  chronosMoveSink(q.data[chronosQueueIdx])

template popFirstRejected*[T](q: var CallbackQueue[T]): T =
  ## The REJECTED shape (round 4, "the tempting 0-barrier dequeue" --
  ## RFC 0001 D9's rejected-shapes list). `copyMem` the slot's raw bytes
  ## into a fresh caller-frame local, then `zeroMem` the slot -- NEVER
  ## routed through `chronosMoveSink`. Structurally real (not a
  ## hand-waved stand-in): this is the literal shape the RFC rejects,
  ## reproduced here so `bmc_ghost.nim` can falsify it mechanically
  ## rather than by prose alone.
  doAssert q.tail > q.head, "CallbackQueue.popFirst(): queue is empty"
  let chronosQueueIdx = slotIndex(q.head, q.data.len)
  inc q.head
  var chronosRejectedLocal: T
  copyMem(addr chronosRejectedLocal, addr q.data[chronosQueueIdx], sizeof(T))
  zeroMem(addr q.data[chronosQueueIdx], sizeof(T))
  chronosRejectedLocal
