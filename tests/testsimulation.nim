#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/simulation.nim`'s `simulate()` harness core (RFC
## 0003 3.8, slice S8): the Defect-to-`SimulationError` conversion for
## internal sim-loop/oracle failures, a raising body's exception-safe
## dispatcher restore (no masking `doAssert`), and the decision/virtual-
## time budgets that turn a livelock into a reported failure instead of
## a hang.

import unittest2
import std/strutils

{.used.}

when defined(chronosSimulation) and compileOption("threads"):
  ## Every probe below drives `simulate()` from its own OS thread, the
  ## same isolation `tests/testsimloop.nim` uses: a real dispatcher
  ## saved/restored here must never be this test binary's shared
  ## per-thread dispatcher.
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

  proc probeEmptyBodyRoundTrips() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let realDisp = getThreadDispatcher()
    simulate(seed = 1'u64):
      discard
    if getThreadDispatcherOrNil() != realDisp:
      outcome = ProbeOutcome(ok: false,
        msg: "the real dispatcher was not restored")
    else:
      try:
        waitFor sleepAsync(1.milliseconds)
      except CatchableError as exc:
        outcome = ProbeOutcome(ok: false,
          msg: "restored dispatcher failed to run: " & exc.msg)
    probeChan.send(outcome)

  proc probeRaisingBodyReportsSeedAndTraceNoMaskingAssert() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let realDisp = getThreadDispatcher()
    try:
      simulate(seed = 0xC0FFEE'u64):
        # Leaves the dying sim dispatcher's callback queue non-empty,
        # exercising the exact restore hazard RFC 0003 3.8 names:
        # `setThreadDispatcher`'s outgoing-queues-empty assert would
        # otherwise fire on this queued-but-never-drained callback and
        # mask the body's own exception.
        callSoon(proc(arg: pointer) {.gcsafe, raises: [].} = discard)
        raise newException(ValueError, "boom from body")
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not propagate the body's error")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.BodyError:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
      elif exc.seed != 0xC0FFEE'u64:
        outcome = ProbeOutcome(ok: false, msg: "wrong seed: " & $exc.seed)
      elif exc.tracePath.len == 0:
        outcome = ProbeOutcome(ok: false, msg: "no trace path recorded")
      elif "boom from body" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "original message lost: " & exc.msg)
      elif exc.parent.isNil or "boom from body" notin exc.parent.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "original exception not chained as parent")
    except AssertionDefect as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "masking assert fired during restore: " & exc.msg)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type escaped simulate(): " & exc.msg)
    if outcome.ok and getThreadDispatcherOrNil() != realDisp:
      outcome = ProbeOutcome(ok: false,
        msg: "the real dispatcher was not restored after a raising body")
    probeChan.send(outcome)

  proc probeDecisionBudgetCatchesZeroDurationLivelock() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithBudget(seed = 5'u64, decisionBudget = 20, timeBudget = 1_000.seconds):
        while true:
          await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not stop the zero-duration timer livelock")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.DecisionBudgetExhausted:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & exc.msg)
    probeChan.send(outcome)

  proc probeDecisionBudgetCatchesPartialWriteRetrySpin() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithBudget(seed = 6'u64, decisionBudget = 20, timeBudget = 1_000.seconds):
        let disp = getThreadDispatcher()
        let cp = IoOutcomePoint(trigger: SimEventId(0'u64),
          endpoint: SimEndpointId(0'u32), op: SimIoOp.Write, maxBytes: 64,
          faults: {})
        while true:
          discard disp.simDecideIo(cp)
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not stop the partial-write retry spin")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.DecisionBudgetExhausted:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & exc.msg)
    probeChan.send(outcome)

  proc probeTimeBudgetCatchesFastVirtualTimeRunaway() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithBudget(seed = 7'u64, decisionBudget = 10_000, timeBudget = 10.seconds):
        while true:
          await sleepAsync(1_000_000.seconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not stop the virtual-time runaway")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.TimeBudgetExhausted:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & exc.msg)
    probeChan.send(outcome)

  proc probeSweepRunsEverySeedAndPasses() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let outcomes = sweepSeeds(0'u64 .. 4'u64):
      discard
    if outcomes.len != 5:
      outcome = ProbeOutcome(ok: false,
        msg: "expected 5 outcomes, got " & $outcomes.len)
    else:
      for i, o in outcomes:
        if not o.passed:
          outcome = ProbeOutcome(ok: false,
            msg: "seed " & $o.seed & " unexpectedly failed: " & o.msg)
        elif o.seed != uint64(i):
          outcome = ProbeOutcome(ok: false,
            msg: "outcome " & $i & " carries seed " & $o.seed &
                 " - not in seed order")
    probeChan.send(outcome)

  proc probeSweepCollectsEveryFailingSeedNotJustFirst() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let outcomes = collectSweepSeeds(20'u64 .. 22'u64,
      simulateDefaultDecisionBudget, simulateDefaultTimeBudget,
      proc(): Future[void] {.async, gcsafe.} =
        raise newException(ValueError, "boom from sweep body"))
    if outcomes.len != 3:
      outcome = ProbeOutcome(ok: false,
        msg: "expected 3 outcomes, got " & $outcomes.len)
    else:
      var seeds: seq[uint64]
      for o in outcomes:
        if o.passed:
          outcome = ProbeOutcome(ok: false,
            msg: "seed " & $o.seed & " unexpectedly passed")
        elif o.kind != SimFailureKind.BodyError:
          outcome = ProbeOutcome(ok: false,
            msg: "seed " & $o.seed & " wrong kind: " & $o.kind)
        elif "boom from sweep body" notin o.msg:
          outcome = ProbeOutcome(ok: false,
            msg: "seed " & $o.seed & " lost its message: " & o.msg)
        seeds.add o.seed
      if outcome.ok and seeds != @[20'u64, 21'u64, 22'u64]:
        outcome = ProbeOutcome(ok: false,
          msg: "not every seed ran, or not in order: " & $seeds)
    probeChan.send(outcome)

  proc pre703FixtureBody() {.async.} =
    ## Reconstructs the shape of upstream #703 (RFC 0003 S9a): two
    ## independent completions race to be observed by a single,
    ## unrepeated check - the real bug's spawned thread posting two
    ## `callSoon` callbacks the dispatcher's queue drain could land
    ## between, with only one drained by the test's single `poll()`.
    ## `simProducer` (S13) is not built yet, so this reconstructs the
    ## same race through the sim seams that exist now: two readiness
    ## events, delivered together in the same batch, in a relative
    ## order `RandomOracle` controls (`decideBatch`'s shuffle, the only
    ## seed-dependent degree of freedom the harness exposes yet).
    ## `producer` models the first post; `reaper` models whatever the
    ## buggy test's single check depended on having already observed it
    ## - if the oracle delivers `reaper` first, `producer` fires only
    ## afterward, past the point its result was needed, the same shape
    ## as the leftover callback that fired through #703's dangling
    ## pointer.
    let disp = getThreadDispatcher()
    var producerRan = false
    var reaperSawProducer = false
    let fdProducer = disp.mintSimFd()
    let fdReaper = disp.mintSimFd()
    discard addReader2(fdProducer, proc(arg: pointer) {.gcsafe, raises: [].} =
      producerRan = true)
    discard addReader2(fdReaper, proc(arg: pointer) {.gcsafe, raises: [].} =
      reaperSawProducer = producerRan)
    discard disp.simMarkReady(fdProducer, SimReadyDirection.Read)
    discard disp.simMarkReady(fdReaper, SimReadyDirection.Read)
    # `poll()` cannot be called directly from async code (illegal
    # `NestedPoll` effect); yielding once is enough, since both
    # readiness events are already deliverable and land in the same
    # batch regardless of which poll iteration inside `await` delivers
    # them.
    await sleepAsync(0.milliseconds)
    if not reaperSawProducer:
      raise newException(ValueError,
        "pre-#703 shape: the producer callback had not fired by the time " &
        "its single check ran - reproduces the upstream #703 under-drain")

  proc probePre703FixtureCaughtBySweepWithSeedReplaying() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let outcomes = collectSweepSeeds(0'u64 .. 15'u64,
      simulateDefaultDecisionBudget, simulateDefaultTimeBudget,
      proc(): Future[void] {.async, gcsafe.} =
        await pre703FixtureBody())
    var failingSeeds: seq[uint64]
    var passingSeeds: seq[uint64]
    for o in outcomes:
      if o.passed: passingSeeds.add o.seed
      else: failingSeeds.add o.seed
    if failingSeeds.len == 0:
      outcome = ProbeOutcome(ok: false,
        msg: "no seed in 0..15 reproduced the race - fixture is not " &
             "exercising the order-dependent hazard")
    elif passingSeeds.len == 0:
      outcome = ProbeOutcome(ok: false,
        msg: "every seed in 0..15 failed - fixture is not seed-dependent")
    else:
      let replaySeed = failingSeeds[0]
      try:
        simulate(seed = replaySeed):
          await pre703FixtureBody()
        outcome = ProbeOutcome(ok: false,
          msg: "seed " & $replaySeed & " failed under the sweep but " &
               "passed on direct replay - not deterministic")
      except SimulationError as exc:
        if exc.kind != SimFailureKind.BodyError:
          outcome = ProbeOutcome(ok: false,
            msg: "replay of seed " & $replaySeed & " raised the wrong " &
                 "kind: " & $exc.kind)
        elif "pre-#703 shape" notin exc.msg:
          outcome = ProbeOutcome(ok: false,
            msg: "replay of seed " & $replaySeed & " lost the message: " &
                 exc.msg)
      except CatchableError as exc:
        outcome = ProbeOutcome(ok: false,
          msg: "replay of seed " & $replaySeed & " raised the wrong " &
               "exception type: " & exc.msg)
    probeChan.send(outcome)

  proc probeDeadlockIsReportedAsSimulationError() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      let fut = newFuture[void]("neverCompletes")
      simulate(seed = 8'u64):
        await fut
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not report the deadlock")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.Deadlock:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & exc.msg)
    probeChan.send(outcome)

  suite "simulate() harness core":
    test "an empty body round-trips the real dispatcher":
      let outcome = runProbe(probeEmptyBodyRoundTrips)
      checkpoint outcome.msg
      check outcome.ok

    test "a raising body reports seed and trace, with no masking assert":
      let outcome = runProbe(probeRaisingBodyReportsSeedAndTraceNoMaskingAssert)
      checkpoint outcome.msg
      check outcome.ok

    test "a zero-duration timer livelock is caught by the decision budget":
      let outcome = runProbe(probeDecisionBudgetCatchesZeroDurationLivelock)
      checkpoint outcome.msg
      check outcome.ok

    test "a partial-write retry spin is caught by the decision budget":
      let outcome = runProbe(probeDecisionBudgetCatchesPartialWriteRetrySpin)
      checkpoint outcome.msg
      check outcome.ok

    test "a fast virtual-time runaway is caught by the time budget":
      let outcome = runProbe(probeTimeBudgetCatchesFastVirtualTimeRunaway)
      checkpoint outcome.msg
      check outcome.ok

    test "quiescence deadlock is reported as a SimulationError":
      let outcome = runProbe(probeDeadlockIsReportedAsSimulationError)
      checkpoint outcome.msg
      check outcome.ok

  suite "sweepSeeds aggregation":
    test "every seed runs, in order, and a well-behaved body passes all of them":
      let outcome = runProbe(probeSweepRunsEverySeedAndPasses)
      checkpoint outcome.msg
      check outcome.ok

    test "every seed runs regardless of its siblings, and every failure is collected":
      let outcome = runProbe(probeSweepCollectsEveryFailingSeedNotJustFirst)
      checkpoint outcome.msg
      check outcome.ok

    test "a pre-#703-shape race is caught by the sweep, with its seed replaying":
      let outcome = runProbe(probePre703FixtureCaughtBySweepWithSeedReplaying)
      checkpoint outcome.msg
      check outcome.ok
