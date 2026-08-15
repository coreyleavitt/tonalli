#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/internal/simledger.nim`'s D8 ghost-ledger laws
## (RFC 0003 3.9, slices S14/S15): callback conservation, future
## lifecycle, contextvar accounting, timer accounting, and waiter
## conservation, checked at step boundaries (`simulateWithLedger`) plus
## a final check at teardown.
##
## Producer-coverage scoping judgment call: ledger checking is opt-in
## (`simulateWithLedger`, never the plain `simulate`/`sweepSeeds` every
## pre-S14 test already uses), so the S1-S13 suites are unaffected by
## construction. The `Callbacks`-queue enqueue instrumentation wired
## into `asyncengine.nim` for this slice covers every producer this
## file's own scenarios exercise (timer expiry, `callSoon`, sim
## readiness delivery, `callIdle`/`internalCallTick`) but not every
## producer in the codebase (e.g. the Windows IOCP completion path, or
## the close/teardown flush paths `SimNet`/transport tests would
## exercise) - extending it to those is follow-on work, not claimed
## here. `SimLedgerError`'s message and `.objectDesc` are checked with
## `notin`/`in` substring assertions rather than pinned verbatim, to
## avoid over-fitting the pinning discipline S3-S5 use for genuine
## ordering guarantees onto a diagnostic message with no such contract.
##
## Slice S15 adds three laws: contextvar accounting and timer
## accounting are checked the same way as S14's laws (real hooks at the
## real capture/restore and arm/fire/cancel touchpoints in
## `asyncengine.nim`); waiter conservation (the 2026-08-15 amendment) is
## different - `asyncsync.nim` gains no seam, so the probes below
## register each primitive explicitly (`simLedgerTrackWaiters`) and the
## law's only enforcement point is `simulate()` teardown (see
## `simledger.nim`'s module docstring for why a per-step reading cannot
## distinguish a legitimate in-flight wait from a leak).

import unittest2
import std/strutils

{.used.}

when defined(chronosSimulation) and compileOption("threads"):
  ## Every probe below drives `simulateWithLedger()` from its own OS
  ## thread, the same isolation `tests/testsimulation.nim` uses.
  import ../chronos
  import ../chronos/simulation

  type
    ProbeOutcome = object
      ok: bool
      msg: string

  var probeChan: Channel[ProbeOutcome]
  probeChan.open()

  template runProbe(threadProc: typed): ProbeOutcome =
    var probeThread: Thread[void]
    createThread(probeThread, threadProc)
    let outcome = probeChan.recv()
    joinThread(probeThread)
    outcome

  # --- happy path: conservation holds with no violation -------------------

  proc probeHappyPathRaisesNothing() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 1'u64):
        for _ in 0 ..< 5:
          await sleepAsync(0.milliseconds)
        let fut = newFuture[void]("test.happyPath")
        callSoon(proc(arg: pointer) {.gcsafe, raises: [].} =
          if not fut.finished(): fut.complete())
        await fut
        callIdle(proc(arg: pointer) {.gcsafe, raises: [].} = discard)
        internalCallTick(proc(arg: pointer) {.gcsafe, raises: [].} = discard)
        await sleepAsync(0.milliseconds)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "unexpected " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- planted dropped callback: callback conservation ---------------------

  proc probePlantedDroppedCallbackCaughtWithSeedStepObject() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 0xDEAD'u64):
        await sleepAsync(0.milliseconds)
        # Plants the violation: tells the ledger to expect one more
        # `Callbacks` enqueue than will ever actually fire, nil-pop, or
        # remain queued at teardown - the #703 bug class (a callback
        # that silently never surfaces) caught structurally.
        simLedgerDebugPlantDroppedEnqueue(SimLedgerQueueKind.Callbacks)
        # The very next real fire's per-step check catches the mismatch.
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWithLedger did not raise for the planted drop")
    except SimLedgerError as exc:
      if exc.seed != 0xDEAD'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif exc.step < 0:
        outcome = ProbeOutcome(ok: false, msg: "no step index: " & $exc.step)
      elif "Callbacks queue" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "object not named: " & exc.objectDesc)
      elif "callback conservation" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      elif not exc.msg.startsWith("simulation invariant violation:"):
        outcome = ProbeOutcome(ok: false,
          msg: "wrong message prefix: " & exc.msg)
      else:
        checkpoint "planted dropped-callback RED evidence: seed=0x" &
          toHex(exc.seed) & " step=" & $exc.step & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- planted double completion: future lifecycle -------------------------

  proc probePlantedDoubleCompletionCaughtWithSeedStepObject() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 0xBEEF'u64):
        let fut = newFuture[void]("test.doubleComplete")
        fut.complete()
        # A real second `finish()` call is unreachable here - it would
        # raise an uncatchable `FutureDefect` first (checkFinished).
        # The debug hook bypasses `finish()` entirely to plant the
        # second transition the ledger's identity registry must catch,
        # from inside an open step (after a real fire has resumed this
        # coroutine) so the violation attributes to a genuine step.
        await sleepAsync(0.milliseconds)
        simLedgerDebugForceFutureState(fut, FutureState.Failed)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWithLedger did not raise for the planted double " &
             "completion")
    except SimLedgerError as exc:
      if exc.seed != 0xBEEF'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif exc.step <= 0:
        outcome = ProbeOutcome(ok: false,
          msg: "expected a step past the synchronous prefix: " & $exc.step)
      elif "Future[" notin exc.objectDesc or
           "created at" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "object not named: " & exc.objectDesc)
      elif "future lifecycle" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      elif "Completed" notin exc.msg or "Failed" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "old/new state not both named: " & exc.msg)
      else:
        checkpoint "planted double-completion RED evidence: seed=0x" &
          toHex(exc.seed) & " step=" & $exc.step & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- cancellation cascade accounts to its enclosing step -----------------

  proc probeCancellationCascadeAccountsToEnclosingStep() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 3'u64):
        let parent = newFuture[void]("test.cascadeParent",
                                      {FutureFlag.OwnCancelSchedule})
        let child = newFuture[void]("test.cascadeChild")
        parent.internalChild = child
        var childCancelled = false
        child.cancelCallback = proc(udata: pointer) {.gcsafe, raises: [].} =
          childCancelled = true
        # Resume inside a real fire, so a step is open, matching the
        # RFC's "one step is one outermost fireWithContext return" -
        # tryCancel's cascade must not itself advance the step index.
        await sleepAsync(0.milliseconds)
        let stepBefore = simLedgerDebugCurrentStep()
        discard tryCancel(parent)
        let stepAfter = simLedgerDebugCurrentStep()
        if not childCancelled:
          outcome = ProbeOutcome(ok: false,
            msg: "cascade did not reach the child's cancelCallback")
        elif not child.cancelled():
          outcome = ProbeOutcome(ok: false, msg: "child was not cancelled")
        elif stepAfter != stepBefore:
          outcome = ProbeOutcome(ok: false,
            msg: "cascade advanced the step index: before=" & $stepBefore &
                 " after=" & $stepAfter)
        else:
          checkpoint "cascade accounted to step " & $stepBefore &
            " (unchanged across tryCancel)"
        await sleepAsync(0.milliseconds)
    except CatchableError as exc:
      if outcome.ok:
        outcome = ProbeOutcome(ok: false,
          msg: "unexpected " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- pre-first-fire cancellation accounts to the teardown check ----------

  proc probePreFirstFireCancellationAccountsToTeardown() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 5'u64):
        # Cancelled from the body's synchronous prefix, before any
        # callback has ever fired - no step is open yet (RFC 0003 3.9:
        # "a cancellation initiated from the body's synchronous prefix
        # ... is still counted; the ledger attributes them to the next
        # step boundary, and a final check runs at simulate() teardown
        # so nothing escapes"). This body never awaits anything, so the
        # only checkpoint that can ever see this future's transition is
        # the teardown check itself.
        let fut = newFuture[void]("test.preFirstFire")
        discard tryCancel(fut)
        doAssert fut.cancelled()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "teardown check wrongly raised: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- nil-function-pop reachability settlement -----------------------------

  proc probeNilFunctionPopUnreachableAcrossRepresentativeRun() {.thread.} =
    ## Settles RFC 0003 3.9's open question for slice S14: every
    ## production site that pushes onto `Callbacks` (`callSoon`,
    ## `capturingCallback`/`bareCallback`-built timer expiry, idler/tick
    ## transfer, the sim readiness/arrival delivery path, close-teardown
    ## interest flush) filters `isNil(callable.function)` before the
    ## push - confirmed by an exhaustive audit of every
    ## `loop.callbacks.addLast(...)` call site in `asyncengine.nim` on
    ## both platform branches. `processCallbacksBody`'s
    ## `if not(isNil(callable.function))` guard is therefore
    ## unreachable in practice, not merely untested - the ledger still
    ## names the category (`nilPopCount`) rather than silently
    ## folding it into `fired`, so a future regression that *did*
    ## introduce a nil-function push would surface as a nonzero count
    ## here, not a silent miscount. This probe exercises a
    ## representative mix of producers (timers, `callSoon`, sim
    ## readiness, idler/tick) and pins the empirical count at zero.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 7'u64):
        for _ in 0 ..< 3:
          await sleepAsync(0.milliseconds)
        let disp = getThreadDispatcher()
        let fd = disp.mintSimFd()
        discard addReader2(fd, proc(arg: pointer) {.gcsafe, raises: [].} =
          discard)
        discard disp.simMarkReady(fd, SimReadyDirection.Read)
        await sleepAsync(0.milliseconds)
        callIdle(proc(arg: pointer) {.gcsafe, raises: [].} = discard)
        internalCallTick(proc(arg: pointer) {.gcsafe, raises: [].} = discard)
        await sleepAsync(0.milliseconds)
        let nilPops = simLedgerDebugNilPopCount(SimLedgerQueueKind.Callbacks)
        if nilPops != 0'u64:
          outcome = ProbeOutcome(ok: false,
            msg: "nil-function pops observed: " & $nilPops &
                 " - reachability settlement is wrong")
        else:
          checkpoint "nil-function-pop count across representative " &
            "producers: " & $nilPops
    except CatchableError as exc:
      if outcome.ok:
        outcome = ProbeOutcome(ok: false,
          msg: "unexpected " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- planted contextvar imbalance: contextvar accounting -----------------

  proc probePlantedContextImbalanceCaughtAtTeardown() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 0xC0DE'u64):
        # A real capture/restore pair (exercises the happy-path
        # touchpoints too) before planting the imbalance, so the
        # violation is genuinely attributable to the plant, not to an
        # unrelated miscount.
        await sleepAsync(0.milliseconds)
        simLedgerDebugPlantContextImbalance()
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWithLedger did not raise for the planted context " &
             "imbalance")
    except SimLedgerError as exc:
      if exc.seed != 0xC0DE'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif "context captures" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "object not named: " & exc.objectDesc)
      elif "contextvar conservation" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      elif not exc.msg.startsWith("simulation invariant violation:"):
        outcome = ProbeOutcome(ok: false,
          msg: "wrong message prefix: " & exc.msg)
      else:
        checkpoint "planted context-imbalance RED evidence: seed=0x" &
          toHex(exc.seed) & " step=" & $exc.step & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- planted timer imbalance: timer accounting ----------------------------

  proc probePlantedTimerImbalanceCaughtAtTeardown() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 0x71DE'u64):
        # A real armed/fired/cancelled mix before planting the
        # imbalance: one timer fires normally, one is cancelled before
        # firing (`clearTimer`, via cancelling the `sleepAsync` future).
        await sleepAsync(0.milliseconds)
        let cancelled = sleepAsync(1.hours)
        discard tryCancel(cancelled)
        simLedgerDebugPlantTimerImbalance()
        # The next real fire's per-fire check catches the mismatch
        # (timer conservation, unlike context conservation, is checked
        # per-fire: `len(loop.timers)` is O(1), so there is no interface
        # constraint forcing a teardown-only cadence here).
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWithLedger did not raise for the planted timer " &
             "imbalance")
    except SimLedgerError as exc:
      if exc.seed != 0x71DE'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif "timer heap" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "object not named: " & exc.objectDesc)
      elif "timer conservation" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      elif not exc.msg.startsWith("simulation invariant violation:"):
        outcome = ProbeOutcome(ok: false,
          msg: "wrong message prefix: " & exc.msg)
      else:
        checkpoint "planted timer-imbalance RED evidence: seed=0x" &
          toHex(exc.seed) & " step=" & $exc.step & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- timer accounting: cancellation reaches the lazy-sweep discard -------

  proc probeTimerCancellationSweptWithoutViolation() {.thread.} =
    ## The planted-imbalance probe above cancels a far-future timer (1
    ## hour out), which the lazy sweep never revisits within the test -
    ## correctly counted as still-`pending`, per this slice's design
    ## (`noteTimerCancelled` fires only when the sweep actually discards
    ## a zombie entry, never at `clearTimer` itself, to avoid double-
    ## counting against `pending` for the interval in between). This
    ## probe cancels a near-future timer instead, so a later real fire's
    ## sweep reaches and discards the zombie within the run, exercising
    ## `noteTimerCancelled` itself - and confirms it does not falsely
    ## violate conservation.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 0x7EA9'u64):
        let toCancel = sleepAsync(1.milliseconds)
        discard tryCancel(toCancel)
        # Both under the same near-future window as `toCancel`, so the
        # sweep that discovers `toCancel`'s zombie has already advanced
        # virtual time past it.
        for _ in 0 ..< 3:
          await sleepAsync(1.milliseconds)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "unexpected " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- waiter conservation: happy path across all five primitives ----------

  proc probeWaiterConservationHappyPath() {.thread.} =
    ## Exercises every primitive the 2026-08-15 amendment names (RFC
    ## 0003 3.9), each with a genuine park-then-wake so the law's
    ## per-instance registration and its `waitersCount`/`gettersCount`/
    ## `puttersCount`-backed accessor plumbing (`simLedgerTrackWaiters`)
    ## are validated against real blocking, not only against primitives
    ## that never parked anything.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 0xA11'u64):
        let lock = newAsyncLock()
        simLedgerTrackWaiters(lock)
        await lock.acquire()
        let lockWaiter = lock.acquire()  # parks: lock is held
        lock.release()
        await lockWaiter
        lock.release()

        let event = newAsyncEvent()
        simLedgerTrackWaiters(event)
        let eventWaiter = event.wait()   # parks: not yet set
        event.fire()
        await eventWaiter

        let queue = newAsyncQueue[int](maxsize = 1)
        simLedgerTrackWaiters(queue)
        await queue.put(1)
        let putterWaiter = queue.put(2)  # parks: queue full
        let firstItem = await queue.get()  # wakes the putter
        doAssert firstItem == 1
        await putterWaiter
        discard await queue.get()

        let eventQueue = newAsyncEventQueue[int]()
        simLedgerTrackWaiters(eventQueue)
        let key = eventQueue.register()
        let waitFut = eventQueue.waitEvents(key)  # parks: nothing queued
        eventQueue.emit(42)
        discard await waitFut
        eventQueue.unregister(key)

        let sema = newAsyncSemaphore(1)
        simLedgerTrackWaiters(sema)
        await sema.acquire()
        let semaWaiter = sema.acquire()  # parks: no slots available
        sema.release()
        await semaWaiter
        sema.release()

        await sleepAsync(0.milliseconds)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "unexpected " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- waiter conservation: leaked AsyncLock waiter caught at teardown -----

  proc probeLeakedAsyncLockWaiterCaughtAtTeardown() {.thread.} =
    ## The RFC 0003 3.9 amendment's motivating leak: a `race()`/`one()`-
    ## style abandoned wait. `race`/`one` complete on the first winner
    ## and only `removeCallback` the losers - they document that losing
    ## futures are never cancelled - so a losing `AsyncLock.acquire()`
    ## stays parked in `lock.waiters` forever. This probe reproduces the
    ## same shape directly (start an `acquire()` against a held lock,
    ## never await or cancel it) rather than importing `race`/`one`,
    ## since the effect on `lock.waiters` is identical either way.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 0x1EA6'u64):
        let lock = newAsyncLock()
        simLedgerTrackWaiters(lock)
        await lock.acquire()
        discard lock.acquire()  # parks, then abandoned: never awaited,
                                 # never cancelled
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWithLedger did not raise for the leaked waiter")
    except SimLedgerError as exc:
      if exc.seed != 0x1EA6'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif "AsyncLock.waiters" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "primitive not named: " & exc.objectDesc)
      elif "waiter conservation" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      elif not exc.msg.startsWith("simulation invariant violation:"):
        outcome = ProbeOutcome(ok: false,
          msg: "wrong message prefix: " & exc.msg)
      else:
        checkpoint "leaked AsyncLock waiter RED evidence: seed=0x" &
          toHex(exc.seed) & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- waiter conservation: leaked AsyncEventQueue reader at teardown ------

  proc probeLeakedAsyncEventQueueWaiterCaughtAtTeardown() {.thread.} =
    ## As the `AsyncLock` leak above, for `AsyncEventQueue` - this
    ## slice's own new accessor (`asyncsync.nim`'s `waitersCount`,
    ## `feat/asyncsync-waiters-introspection` did not cover this
    ## primitive), exercised end to end through the ledger.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithLedger(seed = 0xE9EA'u64):
        let eventQueue = newAsyncEventQueue[int]()
        simLedgerTrackWaiters(eventQueue)
        let key = eventQueue.register()
        discard eventQueue.waitEvents(key)  # parks, then abandoned:
                                             # never awaited, never
                                             # unregistered/cancelled
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWithLedger did not raise for the leaked waiter")
    except SimLedgerError as exc:
      if exc.seed != 0xE9EA'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif "AsyncEventQueue.readers" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "primitive not named: " & exc.objectDesc)
      elif "waiter conservation" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      else:
        checkpoint "leaked AsyncEventQueue waiter RED evidence: seed=0x" &
          toHex(exc.seed) & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  suite "ghost ledgers: callback conservation and future lifecycle":
    test "the happy path raises nothing":
      let outcome = runProbe(probeHappyPathRaisesNothing)
      checkpoint outcome.msg
      check outcome.ok

    test "a planted dropped callback is caught with seed, step, and object":
      let outcome = runProbe(probePlantedDroppedCallbackCaughtWithSeedStepObject)
      checkpoint outcome.msg
      check outcome.ok

    test "a planted double completion is caught with seed, step, and object":
      let outcome = runProbe(probePlantedDoubleCompletionCaughtWithSeedStepObject)
      checkpoint outcome.msg
      check outcome.ok

    test "a cancellation cascade accounts to its enclosing step":
      let outcome = runProbe(probeCancellationCascadeAccountsToEnclosingStep)
      checkpoint outcome.msg
      check outcome.ok

    test "a pre-first-fire cancellation accounts to the teardown check":
      let outcome = runProbe(probePreFirstFireCancellationAccountsToTeardown)
      checkpoint outcome.msg
      check outcome.ok

    test "nil-function pops are unreachable across a representative run":
      let outcome = runProbe(probeNilFunctionPopUnreachableAcrossRepresentativeRun)
      checkpoint outcome.msg
      check outcome.ok

    test "a planted contextvar imbalance is caught at teardown":
      let outcome = runProbe(probePlantedContextImbalanceCaughtAtTeardown)
      checkpoint outcome.msg
      check outcome.ok

    test "a planted timer imbalance is caught":
      let outcome = runProbe(probePlantedTimerImbalanceCaughtAtTeardown)
      checkpoint outcome.msg
      check outcome.ok

    test "a timer cancellation swept during the run raises nothing":
      let outcome = runProbe(probeTimerCancellationSweptWithoutViolation)
      checkpoint outcome.msg
      check outcome.ok

    test "waiter conservation holds across all five primitives' happy path":
      let outcome = runProbe(probeWaiterConservationHappyPath)
      checkpoint outcome.msg
      check outcome.ok

    test "a leaked AsyncLock waiter is caught at teardown naming the primitive":
      let outcome = runProbe(probeLeakedAsyncLockWaiterCaughtAtTeardown)
      checkpoint outcome.msg
      check outcome.ok

    test "a leaked AsyncEventQueue waiter is caught at teardown naming the primitive":
      let outcome = runProbe(probeLeakedAsyncEventQueueWaiterCaughtAtTeardown)
      checkpoint outcome.msg
      check outcome.ok
