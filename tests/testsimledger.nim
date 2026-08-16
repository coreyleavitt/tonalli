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
## conservation, checked at step boundaries (`simulateWith(seed, simOptions(
## ledger = true))`) plus a final check at teardown.
##
## Producer-coverage scoping judgment call: ledger checking is opt-in
## (`simOptions(ledger = true)`, never the plain `simulate`/`sweepSeeds` every
## pre-S14 test already uses), so the S1-S13 suites are unaffected by
## construction. The `Callbacks`-queue enqueue instrumentation wired
## into `asyncengine.nim` for this slice covers every producer this
## file's own scenarios exercise (timer expiry, `callSoon`, sim
## readiness delivery, `callIdle`/`internalCallTick`) and, as of the
## RFC 0003 review round that added `probeTransportCloseConservation`
## below, the sim close/teardown flush paths `SimNet`/transport tests
## exercise (`closeSocket`/`closeHandle`'s `simFlushCloseInterest`, and
## POSIX `closeSocket`'s own flush branch and continuation callback) -
## but not every producer in the codebase (e.g. the Windows IOCP
## completion path), which stays follow-on work, not claimed here.
## `SimLedgerError`'s message and `.objectDesc` are checked with
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
  ## Every probe below drives `simulateWith(seed, simOptions(ledger = true))`
  ## from its own OS thread, the same isolation `tests/testsimulation.nim`
  ## uses.
  import ../chronos
  import ../chronos/simulation
  import ../chronos/contextvars

  type
    ProbeOutcome = object
      ok: bool
      msg: string

  var probeChan: Channel[ProbeOutcome]
  probeChan.open()

  let simLedgerCtxVar = newContextVar("simLedgerCtxVar", 0)

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
      simulateWith(seed = 1'u64, simOptions(ledger = true)):
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
      simulateWith(seed = 0xDEAD'u64, simOptions(ledger = true)):
        await sleepAsync(0.milliseconds)
        # Plants the violation: tells the ledger to expect one more
        # `Callbacks` enqueue than will ever actually fire, nil-pop, or
        # remain queued at teardown - the #703 bug class (a callback
        # that silently never surfaces) caught structurally.
        simLedgerDebugPlantDroppedEnqueue(SimLedgerQueueKind.Callbacks)
        # The very next real fire's per-step check catches the mismatch.
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWith(ledger = true) did not raise for the planted drop")
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
      simulateWith(seed = 0xBEEF'u64, simOptions(ledger = true)):
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
        msg: "simulateWith(ledger = true) did not raise for the planted double " &
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
      simulateWith(seed = 3'u64, simOptions(ledger = true)):
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
      simulateWith(seed = 5'u64, simOptions(ledger = true)):
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
      simulateWith(seed = 7'u64, simOptions(ledger = true)):
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
      simulateWith(seed = 0xC0DE'u64, simOptions(ledger = true)):
        # A real capture/restore pair (exercises the happy-path
        # touchpoints too) before planting the imbalance, so the
        # violation is genuinely attributable to the plant, not to an
        # unrelated miscount.
        await sleepAsync(0.milliseconds)
        simLedgerDebugPlantContextImbalance()
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWith(ledger = true) did not raise for the planted context " &
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

  # --- contextvar conservation: real capture/restore touchpoints -----------

  proc probeContextConservationRealBindAwaitRead() {.thread.} =
    ## The planted-imbalance probe above proves the debug hook is caught;
    ## it never runs a genuine binding through the real capture/restore
    ## touchpoints (`asyncengine.nim`'s `simLedgerNoteEnqueue`/
    ## `noteContextRestored`, wired at S15). This probe binds a real
    ## `ContextVar` across a real await and asserts nothing else: a clean
    ## `simulateWith(ledger = true)` completion is itself the positive pin - the
    ## law's teardown check ran and found the real captures/restores
    ## balanced.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWith(seed = 0x7EA1'u64, simOptions(ledger = true)):
        simLedgerCtxVar.withValue(11):
          if simLedgerCtxVar.value != 11:
            raise newException(ValueError,
              "wrong binding before await: " & $simLedgerCtxVar.value)
          await sleepAsync(0.milliseconds)
          if simLedgerCtxVar.value != 11:
            raise newException(ValueError,
              "wrong binding after await: " & $simLedgerCtxVar.value)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "unexpected " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  proc probeContextConservationTimerCancelThenRearm() {.thread.} =
    ## As the probe above, but with a timer cancelled before it ever
    ## fires, followed by two more timer fires under the same binding -
    ## the "capture on re-armed callbacks" shape: capture is only ever
    ## counted at `processTimers`'s fire-time pop
    ## (`chronos/internal/asyncengine.nim`), never at `setTimer`'s arm
    ## time, so a context-carrying timer cancelled ahead of firing must
    ## contribute nothing to either side of the ledger's captured/
    ## restored count, and the timers that go on to fire afterward, under
    ## the same enclosing binding, must still balance cleanly. Reuses
    ## `probePlantedTimerImbalanceCaughtAtTeardown`'s cancelled-1-hour-
    ## timer idiom, for context accounting instead of timer accounting.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWith(seed = 0x7EA2'u64, simOptions(ledger = true)):
        simLedgerCtxVar.withValue(21):
          let cancelled = sleepAsync(1.hours)
          discard tryCancel(cancelled)
          await sleepAsync(0.milliseconds)
          if simLedgerCtxVar.value != 21:
            raise newException(ValueError,
              "binding lost after cancel-then-rearm: saw " &
              $simLedgerCtxVar.value)
          await sleepAsync(0.milliseconds)
          if simLedgerCtxVar.value != 21:
            raise newException(ValueError,
              "binding lost on the rearmed timer's second fire: saw " &
              $simLedgerCtxVar.value)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "unexpected " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- planted timer imbalance: timer accounting ----------------------------

  proc probePlantedTimerImbalanceCaughtAtTeardown() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWith(seed = 0x71DE'u64, simOptions(ledger = true)):
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
        msg: "simulateWith(ledger = true) did not raise for the planted timer " &
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
      simulateWith(seed = 0x7EA9'u64, simOptions(ledger = true)):
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
      simulateWith(seed = 0xA11'u64, simOptions(ledger = true)):
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
      simulateWith(seed = 0x1EA6'u64, simOptions(ledger = true)):
        let lock = newAsyncLock()
        simLedgerTrackWaiters(lock)
        await lock.acquire()
        discard lock.acquire()  # parks, then abandoned: never awaited,
                                 # never cancelled
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWith(ledger = true) did not raise for the leaked waiter")
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
      simulateWith(seed = 0xE9EA'u64, simOptions(ledger = true)):
        let eventQueue = newAsyncEventQueue[int]()
        simLedgerTrackWaiters(eventQueue)
        let key = eventQueue.register()
        discard eventQueue.waitEvents(key)  # parks, then abandoned:
                                             # never awaited, never
                                             # unregistered/cancelled
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWith(ledger = true) did not raise for the leaked waiter")
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

  # --- waiter conservation: leaked AsyncEvent waiter at teardown ------------

  proc probeLeakedAsyncEventWaiterCaughtAtTeardown() {.thread.} =
    ## As the `AsyncLock` leak above, for `AsyncEvent`.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWith(seed = 0x3EA7'u64, simOptions(ledger = true)):
        let event = newAsyncEvent()
        simLedgerTrackWaiters(event)
        discard event.wait()  # parks, then abandoned: never awaited,
                               # never set, never cancelled
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWith(ledger = true) did not raise for the leaked waiter")
    except SimLedgerError as exc:
      if exc.seed != 0x3EA7'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif "AsyncEvent.waiters" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "primitive not named: " & exc.objectDesc)
      elif "waiter conservation" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      elif not exc.msg.startsWith("simulation invariant violation:"):
        outcome = ProbeOutcome(ok: false,
          msg: "wrong message prefix: " & exc.msg)
      else:
        checkpoint "leaked AsyncEvent waiter RED evidence: seed=0x" &
          toHex(exc.seed) & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- waiter conservation: leaked AsyncQueue getter waiter at teardown -----

  proc probeLeakedAsyncQueueGetterWaiterCaughtAtTeardown() {.thread.} =
    ## As the `AsyncLock` leak above, for `AsyncQueue`'s getter list -
    ## tracked separately from its putter list (the next probe below),
    ## the "per waiter list" two-list accounting the RFC 0003 3.9
    ## amendment names.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWith(seed = 0x6E77'u64, simOptions(ledger = true)):
        let queue = newAsyncQueue[int]()
        simLedgerTrackWaiters(queue)
        discard queue.get()  # parks: queue empty, then abandoned: never
                              # awaited, never cancelled
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWith(ledger = true) did not raise for the leaked waiter")
    except SimLedgerError as exc:
      if exc.seed != 0x6E77'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif "AsyncQueue.getters" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "primitive not named: " & exc.objectDesc)
      elif "waiter conservation" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      elif not exc.msg.startsWith("simulation invariant violation:"):
        outcome = ProbeOutcome(ok: false,
          msg: "wrong message prefix: " & exc.msg)
      else:
        checkpoint "leaked AsyncQueue getter waiter RED evidence: seed=0x" &
          toHex(exc.seed) & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- waiter conservation: leaked AsyncQueue putter waiter at teardown -----

  proc probeLeakedAsyncQueuePutterWaiterCaughtAtTeardown() {.thread.} =
    ## As the getter probe above, for `AsyncQueue`'s putter list -
    ## the two-list accounting's other half.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWith(seed = 0x6E88'u64, simOptions(ledger = true)):
        let queue = newAsyncQueue[int](maxsize = 1)
        simLedgerTrackWaiters(queue)
        await queue.put(1)
        discard queue.put(2)  # parks: queue full, then abandoned: never
                               # awaited, never cancelled
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWith(ledger = true) did not raise for the leaked waiter")
    except SimLedgerError as exc:
      if exc.seed != 0x6E88'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif "AsyncQueue.putters" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "primitive not named: " & exc.objectDesc)
      elif "waiter conservation" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      elif not exc.msg.startsWith("simulation invariant violation:"):
        outcome = ProbeOutcome(ok: false,
          msg: "wrong message prefix: " & exc.msg)
      else:
        checkpoint "leaked AsyncQueue putter waiter RED evidence: seed=0x" &
          toHex(exc.seed) & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- waiter conservation: leaked AsyncSemaphore waiter at teardown --------

  proc probeLeakedAsyncSemaphoreWaiterCaughtAtTeardown() {.thread.} =
    ## As the `AsyncLock` leak above, for `AsyncSemaphore`.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWith(seed = 0x5EA5'u64, simOptions(ledger = true)):
        let sema = newAsyncSemaphore(1)
        simLedgerTrackWaiters(sema)
        await sema.acquire()
        discard sema.acquire()  # parks: no slots available, then
                                 # abandoned: never awaited, never
                                 # released
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWith(ledger = true) did not raise for the leaked waiter")
    except SimLedgerError as exc:
      if exc.seed != 0x5EA5'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif "AsyncSemaphore.waiters" notin exc.objectDesc:
        outcome = ProbeOutcome(ok: false,
          msg: "primitive not named: " & exc.objectDesc)
      elif "waiter conservation" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "law not named in message: " & exc.msg)
      elif not exc.msg.startsWith("simulation invariant violation:"):
        outcome = ProbeOutcome(ok: false,
          msg: "wrong message prefix: " & exc.msg)
      else:
        checkpoint "leaked AsyncSemaphore waiter RED evidence: seed=0x" &
          toHex(exc.seed) & " " & exc.msg
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  # --- transport close-flush: callback conservation across teardown --------

  when not defined(windows):
    proc probeTransportCloseConservation() {.thread.} =
      ## The `SimNet` idiom `tests/testsimnet.nim` runs under plain
      ## `simulate()` (ledger checking off), exercised here under
      ## `simulateWith(seed, simOptions(ledger = true))` instead: `closeWait`
      ## drives `closeSocket`'s
      ## sim flush branch and its POSIX continuation callback, both of
      ## which enqueue onto `Callbacks` outside this slice's original
      ## instrumentation.
      var outcome = ProbeOutcome(ok: true)
      try:
        simulateWith(seed = 1234'u64, simOptions(ledger = true)):
          let net = simNet()
          let address = initTAddress("127.0.0.1:0")
          let server = net.listenStream(address)
          let acceptFut = server.accept()
          let client = await net.connectStream(address)
          let serverTransp = await acceptFut
          await client.closeWait()
          await serverTransp.closeWait()
      except CatchableError as exc:
        outcome = ProbeOutcome(ok: false,
          msg: "unexpected " & $exc.name & ": " & exc.msg)
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

    test "a real binding across a real await balances the ledger cleanly":
      let outcome = runProbe(probeContextConservationRealBindAwaitRead)
      checkpoint outcome.msg
      check outcome.ok

    test "a real binding across a cancelled-then-rearmed timer balances the ledger cleanly":
      let outcome = runProbe(probeContextConservationTimerCancelThenRearm)
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

    test "a leaked AsyncEvent waiter is caught at teardown naming the primitive":
      let outcome = runProbe(probeLeakedAsyncEventWaiterCaughtAtTeardown)
      checkpoint outcome.msg
      check outcome.ok

    test "a leaked AsyncQueue getter waiter is caught at teardown naming the primitive":
      let outcome = runProbe(probeLeakedAsyncQueueGetterWaiterCaughtAtTeardown)
      checkpoint outcome.msg
      check outcome.ok

    test "a leaked AsyncQueue putter waiter is caught at teardown naming the primitive":
      let outcome = runProbe(probeLeakedAsyncQueuePutterWaiterCaughtAtTeardown)
      checkpoint outcome.msg
      check outcome.ok

    test "a leaked AsyncSemaphore waiter is caught at teardown naming the primitive":
      let outcome = runProbe(probeLeakedAsyncSemaphoreWaiterCaughtAtTeardown)
      checkpoint outcome.msg
      check outcome.ok

    when not defined(windows):
      test "closing a SimNet transport pair does not falsely violate callback conservation":
        let outcome = runProbe(probeTransportCloseConservation)
        checkpoint outcome.msg
        check outcome.ok
