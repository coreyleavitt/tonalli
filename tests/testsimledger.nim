#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/internal/simledger.nim`'s D8 ghost-ledger laws
## (RFC 0003 3.9, slice S14): callback conservation and future
## lifecycle, checked at step boundaries (`simulateWithLedger`) plus a
## final check at teardown.
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
