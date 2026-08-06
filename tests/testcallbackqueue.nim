## Freestanding test suite for `chronos/internal/callbackqueue.nim`.
## Deliberately independent of the contextvars feature and its test
## files: `CallbackQueue[T]` is a general-purpose dispatcher substrate
## (it backs `callbacks`/`idlers`/`ticks`, none of which are
## contextvars-specific), so its coverage must not require the
## contextvars suite either to build or to make sense standing alone.
##
## Includes coverage for growth triggered mid-drain, by a callback
## reentrantly scheduling more work while the pop cursor (`head`) has
## already advanced past the queue's start — exactly the shape
## `asyncengine.nim`'s default (non-strict-reentrancy) drain protocol
## allows (`callSoon` from inside a firing callback).

import unittest2
import ../chronos/internal/callbackqueue

{.used.}

type
  TestPayload = ref object
    value: int

  TestItem = object
    tag: int
    payload: TestPayload

proc newItem(tag: int): TestItem =
  TestItem(tag: tag, payload: TestPayload(value: tag))

proc drain(q: var CallbackQueue[TestItem]): seq[int] =
  ## Pop everything currently in `q` (a plain len-snapshot drain, no
  ## sentinel), in FIFO order, returning the popped tags.
  let n = q.len
  for _ in 0 ..< n:
    let item = q.popFirst()
    result.add(item.tag)

suite "CallbackQueue: basic semantics":
  test "zero-value queue is valid and empty":
    # The zero value must be a usable, empty queue with no
    # `initCallbackQueue` call — `asyncengine.nim`'s POSIX `ticks` field
    # relies on exactly this (never explicitly constructed).
    var q: CallbackQueue[TestItem]
    check q.len == 0

    # First `addLast` on a never-initialized queue must lazily grow from
    # capacity zero rather than fault.
    q.addLast(newItem(1))
    check q.len == 1
    check q.popFirst().tag == 1
    check q.len == 0

  test "FIFO order, single push/pop":
    var q = initCallbackQueue[TestItem]()
    q.addLast(newItem(1))
    q.addLast(newItem(2))
    q.addLast(newItem(3))
    check q.len == 3
    check q.popFirst().tag == 1
    check q.popFirst().tag == 2
    check q.popFirst().tag == 3
    check q.len == 0

  test "initCallbackQueue rounds capacity up to a power of two":
    # Not directly observable through the public interface (no `cap`
    # accessor — by design the interface is exactly five entry points),
    # so this exercises the rounding indirectly: a queue requested with a
    # non-power-of-two initial capacity must still accept at least that
    # many items without growing prematurely in a way that corrupts order.
    var q = initCallbackQueue[TestItem](5)
    for i in 0 ..< 5:
      q.addLast(newItem(i))
    check q.len == 5
    for i in 0 ..< 5:
      check q.popFirst().tag == i

  test "addFirst ordering: sentinel re-insertion at the front":
    # Mirrors the sole real caller (asyncengine.nim's poll(): re-inserting
    # a sentinel at the front of an already-fully-drained batch).
    var q = initCallbackQueue[TestItem]()
    q.addLast(newItem(10))
    discard q.popFirst() # drain to empty, as the real caller always does
    check q.len == 0

    q.addFirst(newItem(999))
    q.addLast(newItem(1))
    q.addLast(newItem(2))
    check q.len == 3
    check q.popFirst().tag == 999
    check q.popFirst().tag == 1
    check q.popFirst().tag == 2

  test "sentinel field fidelity through moves (full-struct value, not identity)":
    # The sentinel is compared by full-struct VALUE
    # (`isSentinel` in asyncengine.nim), so a move-based queue owes field
    # fidelity, not pointer identity of the AsyncCallback struct itself —
    # but the `ref` field it carries (`context`, mirrored here by
    # `payload`) must survive as the SAME ref, not a copy, through
    # addLast/popFirst and across a growth relocation.
    var q = initCallbackQueue[TestItem](2)
    let sentinel = newItem(-1)
    let sentinelPayloadAddr = cast[int](sentinel.payload)

    q.addLast(sentinel)
    # Force growth while the sentinel is still queued, to prove the
    # relocation path preserves the ref field too.
    q.addLast(newItem(1))
    q.addLast(newItem(2))
    q.addLast(newItem(3))

    let popped = q.popFirst()
    check popped.tag == -1
    check popped == sentinel
    check cast[int](popped.payload) == sentinelPayloadAddr
    check popped.payload.value == -1

    # Drain the rest so the test doesn't leave state for later tests.
    discard drain(q)

suite "CallbackQueue: growth":
  test "growth preserves order, non-wrapped region":
    var q = initCallbackQueue[TestItem](2)
    const count = 50
    for i in 0 ..< count:
      q.addLast(newItem(i))
    check q.len == count
    for i in 0 ..< count:
      check q.popFirst().tag == i
    check q.len == 0

  test "wrapped-region growth: live region spans the physical end of the buffer":
    # Advance head/tail past a wrap boundary first (push then pop enough
    # to leave the live region straddling index `cap - 1` / `0`), then
    # push past capacity so `grow()` must relocate a physically
    # wrapped two-segment live region.
    var q = initCallbackQueue[TestItem](4)
    for i in 0 ..< 4:
      q.addLast(newItem(i))
    # Drain 3, leaving one live item at the tail end of the backing array
    # and head/tail advanced (monotonic, so head=3, tail=4 logically, but
    # physically slot 3 of a 4-slot buffer -- next addLast wraps to slot 0).
    for i in 0 ..< 3:
      check q.popFirst().tag == i
    check q.len == 1

    # Refill: tail wraps physically to slots 0,1,2 while head is still
    # anchored at physical slot 3 -- the live region is now physically
    # split across the end and start of the buffer (item 3 at slot 3,
    # items 4,5,6 at slots 0,1,2). Pushing the 4th item (tag 7) fills the
    # queue to its old capacity of 4 and then immediately exceeds it,
    # triggering `grow()` on a genuinely wrapped live region -- the two
    # `copyMem` segments must reassemble slot 3 then slots 0..2 into
    # logical order, not physical order.
    for i in 4 ..< 8:
      q.addLast(newItem(i))
    check q.len == 5 # item 3 (never popped) + items 4..7, post-grow

    # One more push lands in the freshly grown (cap 8), non-wrapped region.
    q.addLast(newItem(8))
    check q.len == 6

    let popped = drain(q)
    check popped == @[3, 4, 5, 6, 7, 8]

  test "repeated growth cycles preserve ref-field values under memory pressure":
    # `grow()`'s two `zeroMem` calls are not cosmetic -- dropping either
    # one leaves a stale, un-zeroed slot in the OLD backing array; when
    # that old seq's destructor later runs, it decrefs the
    # (already-relocated) `ref` field a SECOND time (the real `grow()`'s
    # own doc comment states this explicitly). A single growth event, as
    # in the tests above, does not reliably surface this -- the
    # corruption depends on the freed memory being reused before the
    # stale reference is read again. Repeated growth cycles interleaved
    # with unrelated heap allocations (to encourage prompt reuse of
    # whatever `grow()` just freed) give the corruption many more chances
    # to manifest.
    var q = initCallbackQueue[TestItem](2)
    var expected: seq[int]
    var popped: seq[int]
    for cycle in 0 ..< 200:
      # Push enough to force a grow() most cycles; pop most of them back
      # off, but leave a couple alive across the boundary so grow()
      # relocates a genuinely live, ref-bearing region every time.
      for i in 0 ..< 6:
        let tag = cycle * 10 + i
        q.addLast(newItem(tag))
        expected.add tag
      for i in 0 ..< 4:
        let item = q.popFirst()
        popped.add item.tag
        check item.payload.value == item.tag
      # Unrelated heap noise: encourages the allocator to reuse whatever
      # `grow()` just freed, so a stale un-zeroed slot's double-decref (if
      # present) corrupts something observable instead of sitting inert.
      discard newSeq[int](64)
      discard newString(64)

    while q.len > 0:
      let item = q.popFirst()
      popped.add item.tag
      check item.payload.value == item.tag

    check popped == expected

  test "growth during reentrant drain across capacity boundaries":
    # The exact shape `asyncengine.nim`'s default drain protocol allows:
    # a callback fires (via popFirst, `head` already advanced past the
    # queue's start) and, before the batch finishes, reentrantly
    # schedules more work onto the SAME live queue. Each popped item here
    # schedules two more (net +1 per iteration) so `q.len` is driven past
    # its initial capacity WHILE `head` is already partway through the
    # buffer -- `grow()` must run under a live, advanced (not fresh/zero)
    # pop cursor. Currently exercised by zero tests anywhere in the suite.
    var q = initCallbackQueue[TestItem](4)
    q.addLast(newItem(0))

    var processed: seq[int]
    var nextTag = 1
    var scheduled = 1 # item 0, already scheduled above
    const totalToSchedule = 25

    while q.len > 0:
      let item = q.popFirst()
      processed.add(item.tag)
      for _ in 0 ..< 2:
        if scheduled < totalToSchedule:
          q.addLast(newItem(nextTag))
          inc nextTag
          inc scheduled
      # Net queue growth of +1 per iteration while scheduling budget
      # remains drives `q.len` past capacity 4 within the first few
      # iterations -- by which point several items have already been
      # popped from the front, so `grow()`'s relocation runs against a
      # genuinely advanced `head`, not a freshly-filled queue.

    check processed.len == totalToSchedule
    for i, tag in processed:
      check tag == i
    check q.len == 0

suite "CallbackQueue: integrity under unwind":
  test "post-Defect-unwind queue integrity":
    # `popFirst`'s slot mutation (advancing `head`, clearing the vacated
    # slot) happens before the popped value is handed to the caller for
    # processing -- so a callback that raises must not corrupt the queue
    # for subsequent drains. Mirrors the real dispatcher's shape: a
    # callback body raising inside `fireWithContext` propagates out of
    # `processCallbacksBody`'s popping loop entirely (surfaced as a
    # Defect via `raiseAsDefect` in the real `poll()`) -- so the `try`
    # here wraps the whole drain loop, not a single iteration, to
    # reproduce an actual unwind out of the loop rather than a
    # same-iteration catch.
    var q = initCallbackQueue[TestItem](4)
    for i in 0 ..< 6:
      q.addLast(newItem(i))

    var processed: seq[int]
    var raised = false
    try:
      while q.len > 0:
        let item = q.popFirst()
        if item.tag == 3:
          raise (ref ValueError)(msg: "simulated callback failure")
        processed.add(item.tag)
    except ValueError:
      raised = true

    check raised
    check processed == @[0, 1, 2]
    # Item 3 was popped (head already advanced past it before the raise)
    # but never reached `processed` -- consumed and discarded, not
    # corrupting the queue.
    check q.len == 2 # items 4, 5 remain, unprocessed

    # The queue must still be fully usable afterward, exactly as the real
    # dispatcher's next `poll()` cycle would require.
    check q.popFirst().tag == 4
    check q.popFirst().tag == 5
    check q.len == 0
    q.addLast(newItem(100))
    check q.popFirst().tag == 100

suite "CallbackQueue: raw-access guardrail":
  test "private fields do not compile from outside the module":
    # `data`/`head`/`tail` are private; every touch must go through the
    # five public entry points.
    check(not compiles(block:
      var q: CallbackQueue[TestItem]
      discard q.data))
    check(not compiles(block:
      var q: CallbackQueue[TestItem]
      discard q.head))
    check(not compiles(block:
      var q: CallbackQueue[TestItem]
      discard q.tail))
