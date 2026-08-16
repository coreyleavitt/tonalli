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
import std/[os, strutils]

{.used.}

when defined(chronosSimulation) and compileOption("threads"):
  ## Every probe below drives `simulate()` from its own OS thread, the
  ## same isolation `tests/testsimloop.nim` uses: a real dispatcher
  ## saved/restored here must never be this test binary's shared
  ## per-thread dispatcher.
  import results
  import ../chronos
  import ../chronos/simulation

  type
    ProbeOutcome = object
      ok: bool
      msg: string

  var probeChan: Channel[ProbeOutcome]
  probeChan.open()

  var argEvalCount = 0
    ## R2-6 pin (see `probeSimulateEvaluatesSeedArgumentExactlyOnce`/
    ## `probeSimulateReplayEvaluatesTracePathArgumentExactlyOnce` below):
    ## reset by each probe before use, incremented by that probe's own
    ## side-effecting `seed`/`tracePath` argument expression.

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

  proc probeBodyBarrierHitClassifiedAsBarrierHit() {.thread.} =
    ## A body that reaches a provenance-guarded touch site directly
    ## (`addReader2` on a real, non-sim-minted fd) propagates
    ## `SimBarrierError` unchanged, the "propagation" case
    ## `runSimulation`'s docstring names. Finding 6: this must classify
    ## `SimFailureKind.BarrierHit`, a hermeticity violation distinct
    ## from an ordinary body bug, not fold into `BodyError`.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulate(seed = 11'u64):
        discard addReader2(AsyncFD(999_999),
          proc(arg: pointer) {.gcsafe, raises: [].} = discard)
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not propagate the barrier hit")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.BarrierHit:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
      elif exc.parent.isNil or not (exc.parent of SimBarrierError):
        outcome = ProbeOutcome(ok: false,
          msg: "parent was not a SimBarrierError")
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type escaped simulate(): " & exc.msg)
    probeChan.send(outcome)

  proc probeDefectEnvelopedBarrierHitClassifiedAsBarrierHit() {.thread.} =
    ## The Defect-envelope case `runSimulation`'s docstring names: a
    ## callback crossing a `raises: []`-typed boundary catches its own
    ## `SimBarrierError` and re-raises it wrapped in a `Defect`
    ## (`raiseAsDefect`), mirroring the production idiom at, e.g.,
    ## `chronos/internal/asyncengine.nim`'s `closeSocket()` continuation.
    ## Finding 6: recovered here by type, this must also classify
    ## `SimFailureKind.BarrierHit`, with the original `SimBarrierError`
    ## still reachable as `.parent`.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulate(seed = 12'u64):
        let disp = getThreadDispatcher()
        let fd = disp.mintSimFd()
        discard addReader2(fd, proc(arg: pointer) {.gcsafe, raises: [].} =
          try:
            raiseSimBarrier("test callback touch site")
          except SimBarrierError as exc:
            raiseAsDefect(exc, "test: callback hit a sim barrier"))
        discard disp.simMarkReady(fd, SimReadyDirection.Read)
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not propagate the defect-enveloped barrier hit")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.BarrierHit:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
      elif exc.parent.isNil or not (exc.parent of SimBarrierError):
        outcome = ProbeOutcome(ok: false,
          msg: "parent was not a SimBarrierError")
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type escaped simulate(): " & exc.msg)
    probeChan.send(outcome)

  proc probeSweepClassifiesBarrierHitByKind() {.thread.} =
    ## Finding 6's sweep gap: a body that barriers on every seed must
    ## report `SimSeedOutcome.kind == SimFailureKind.BarrierHit` for
    ## each failing seed, by enum, never by a message substring.
    var outcome = ProbeOutcome(ok: true)
    let outcomes = collectSweepSeeds(30'u64 .. 32'u64,
      simulateDefaultDecisionBudget, simulateDefaultTimeBudget,
      proc(): Future[void] {.async, gcsafe.} =
        discard addReader2(AsyncFD(999_999),
          proc(arg: pointer) {.gcsafe, raises: [].} = discard))
    if outcomes.len != 3:
      outcome = ProbeOutcome(ok: false,
        msg: "expected 3 outcomes, got " & $outcomes.len)
    else:
      for o in outcomes:
        if o.passed:
          outcome = ProbeOutcome(ok: false,
            msg: "seed " & $o.seed & " unexpectedly passed")
        elif o.failureKind != SimSeedFailureKind.Engine:
          outcome = ProbeOutcome(ok: false,
            msg: "seed " & $o.seed & " wrong failureKind: " & $o.failureKind)
        elif o.kind != SimFailureKind.BarrierHit:
          outcome = ProbeOutcome(ok: false,
            msg: "seed " & $o.seed & " wrong kind: " & $o.kind)
    probeChan.send(outcome)

  proc probeScriptedOracleThroughHarnessKeepsGuarantees() {.thread.} =
    ## Finding 5's seam: a scripted oracle driven through the full
    ## harness (`simulateWithOracle`), not a throwaway `newSimDispatcher`/
    ## `setThreadDispatcher` pair on its own thread - proves the harness
    ## guarantees (restore-on-any-outcome, typed `SimulationError`
    ## classification, trace recording) hold around it exactly as they
    ## do for `RandomOracle`.
    var outcome = ProbeOutcome(ok: true)
    let realDisp = getThreadDispatcher()
    let oracle = newSimOracle(defaultDecideBatch, defaultDecideIo,
                               defaultDecideTime)
    try:
      simulateWithOracle(seed = 9'u64, oracle = oracle):
        raise newException(ValueError, "boom from scripted-oracle body")
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWithOracle did not propagate the body's error")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.BodyError:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
      elif "boom from scripted-oracle body" notin exc.msg:
        outcome = ProbeOutcome(ok: false,
          msg: "original message lost: " & exc.msg)
      elif not fileExists(exc.tracePath):
        outcome = ProbeOutcome(ok: false,
          msg: "no trace file written: " & exc.tracePath)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type escaped simulateWithOracle(): " & exc.msg)
    if outcome.ok and getThreadDispatcherOrNil() != realDisp:
      outcome = ProbeOutcome(ok: false,
        msg: "the real dispatcher was not restored after a scripted-oracle run")
    probeChan.send(outcome)

  proc probeOracleDeferralThroughHarnessClassifiedAsOracleDeferral() {.thread.} =
    ## Finding 8's full-run gap: `tests/testsimloop.nim`'s
    ## `probeOracleDeferralNotDeadlock` pins `SimFailureKind.OracleDeferral`
    ## against a bare dispatcher's `poll()` directly - nothing pinned the
    ## same failure surfacing through the full `simulate()` harness as
    ## `SimulationError.kind == OracleDeferral`, the shape a real caller
    ## actually catches. A scripted oracle that defers all deliverable
    ## work with no fallback (no armed timers, no queued callbacks)
    ## against a body with one ready reader reproduces the same shape
    ## through `simulateWithOracle` - awaiting a future the deferred
    ## reader callback would otherwise complete, never a timer: an
    ## armed timer is itself a legal fallback (3.5's deferral protocol),
    ## so this probe must arm none, the same "no fallback" shape
    ## `probeOracleDeferralNotDeadlock` reproduces directly against
    ## `poll()`.
    var outcome = ProbeOutcome(ok: true)
    proc decideBatchDefer(cp: SelectBatchPoint):
        Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
      ok(BatchDecision(order: @[]))
    let oracle = newSimOracle(decideBatchDefer, defaultDecideIo,
                               defaultDecideTime)
    try:
      simulateWithOracle(seed = 14'u64, oracle = oracle):
        let disp = getThreadDispatcher()
        let fd = disp.mintSimFd()
        let fut = newFuture[void]("oracleDeferral")
        discard addReader2(fd, proc(arg: pointer) {.gcsafe, raises: [].} =
          if not fut.finished(): fut.complete())
        discard disp.simMarkReady(fd, SimReadyDirection.Read)
        await fut
      outcome = ProbeOutcome(ok: false,
        msg: "simulateWithOracle did not report the oracle deferral")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.OracleDeferral:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & exc.msg)
    probeChan.send(outcome)

  proc replayFixtureBody(maxBytes: int): Future[void] {.async.} =
    ## Shared shape for the `simulateReplay` probe below: one `decideIo`
    ## choice point whose `maxBytes` is the knob that makes two calls
    ## either identical (same recorded/live digest) or divergent (same
    ## ids, different payload - the exact "payload-changed io fixture"
    ## shape `tests/testsimoracle.nim`'s engine-level suite already
    ## proves `ReplayOracle` detects), now proven through the full
    ## `simulateReplay` harness instead of a hand-built `SimEngineState`.
    let disp = getThreadDispatcher()
    let cp = IoOutcomePoint(trigger: SimEventId(0'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Read, maxBytes: maxBytes,
      faults: {})
    discard disp.simDecideIo(cp)

  proc probeReplayReproducesRecordedRunAndDetectsDivergence() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let seed = 0xFEED'u64
    let tracePath = simTracePath(seed)
    try:
      simulate(seed = seed):
        await replayFixtureBody(64)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "recording run unexpectedly failed: " & exc.msg)

    if outcome.ok:
      try:
        simulateReplay(tracePath):
          await replayFixtureBody(64)
      except CatchableError as exc:
        outcome = ProbeOutcome(ok: false,
          msg: "replay of the identical body raised: " & exc.msg)

    if outcome.ok:
      try:
        simulateReplay(tracePath):
          await replayFixtureBody(128)
        outcome = ProbeOutcome(ok: false,
          msg: "simulateReplay did not detect the divergent body")
      except SimulationError as exc:
        if exc.kind != SimFailureKind.ProtocolViolation:
          outcome = ProbeOutcome(ok: false,
            msg: "divergence raised the wrong kind: " & $exc.kind)
        elif "replay divergence" notin exc.msg:
          outcome = ProbeOutcome(ok: false,
            msg: "divergence not named in message: " & exc.msg)
      except CatchableError as exc:
        outcome = ProbeOutcome(ok: false,
          msg: "divergence raised the wrong exception type: " & exc.msg)
    probeChan.send(outcome)

  proc probeSweepWithLedgerClassifiesViolatingSeedsByKind() {.thread.} =
    ## Finding 12's sweep gap: `sweepSeedsWithLedger` over a body that
    ## plants a ledger violation only on the sweep's second seed (the
    ## same planted-imbalance idiom `tests/testsimledger.nim` uses for a
    ## single run) - the violating seed's outcome must be a
    ## `SimSeedOutcome` failure classified `SimSeedFailureKind.Ledger`,
    ## never a process-ending raise, and its non-violating siblings must
    ## still pass alongside it.
    var outcome = ProbeOutcome(ok: true)
    var runIndex = 0
    let outcomes = sweepSeedsWithLedger(100'u64 .. 102'u64):
      await sleepAsync(0.milliseconds)
      inc runIndex
      if runIndex == 2:
        simLedgerDebugPlantDroppedEnqueue(SimLedgerQueueKind.Callbacks)
      await sleepAsync(0.milliseconds)
    if outcomes.len != 3:
      outcome = ProbeOutcome(ok: false,
        msg: "expected 3 outcomes, got " & $outcomes.len)
    else:
      for i, o in outcomes:
        if i == 1:
          if o.passed:
            outcome = ProbeOutcome(ok: false,
              msg: "seed " & $o.seed & " unexpectedly passed")
          elif o.failureKind != SimSeedFailureKind.Ledger:
            outcome = ProbeOutcome(ok: false,
              msg: "seed " & $o.seed & " wrong failureKind: " & $o.failureKind)
          elif "callback conservation" notin o.msg:
            outcome = ProbeOutcome(ok: false,
              msg: "seed " & $o.seed & " lost the law name: " & o.msg)
        elif not o.passed:
          outcome = ProbeOutcome(ok: false,
            msg: "seed " & $o.seed & " unexpectedly failed (" &
                 $o.failureKind & "): " & o.msg)
    probeChan.send(outcome)

  proc probeBudgetAndLedgerCombinationCompilesAndRuns() {.thread.} =
    ## Finding 12's other gap: no entry point covered budget override
    ## and ledger checking together.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulateWithBudgetAndLedger(seed = 12'u64, decisionBudget = 500,
                                   timeBudget = 10.seconds):
        await sleepAsync(0.milliseconds)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "unexpected " & $exc.name & ": " & exc.msg)
    probeChan.send(outcome)

  proc probeDefectEnvelopedEngineErrorRecoversItsKind() {.thread.} =
    ## Findings 17/18: the Defect-envelope recovery path is already
    ## pinned for `SimBarrierError` (`probeDefectEnvelopedBarrierHitClassifiedAsBarrierHit`
    ## above) and for a planted `SimLedgerError`
    ## (`tests/testsimledger.nim`) - this is the remaining corner, a
    ## genuine `SimEngineError` crossing the same `raises: []`-typed
    ## boundary and being recovered to its own carried `SimFailureKind`
    ## (never folded into `BarrierHit` or `BodyError`), the same
    ## `raiseAsDefect` idiom, mirroring a production `SimEngineError`
    ## boundary rather than the barrier one.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulate(seed = 13'u64):
        let disp = getThreadDispatcher()
        let fd = disp.mintSimFd()
        discard addReader2(fd, proc(arg: pointer) {.gcsafe, raises: [].} =
          try:
            raiseSimEngineError(SimFailureKind.ProtocolViolation,
              "test callback touch site")
          except SimEngineError as exc:
            raiseAsDefect(exc, "test: callback hit a sim engine error"))
        discard disp.simMarkReady(fd, SimReadyDirection.Read)
        await sleepAsync(0.milliseconds)
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not propagate the defect-enveloped engine error")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.ProtocolViolation:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
      elif exc.parent.isNil or not (exc.parent of SimEngineError):
        outcome = ProbeOutcome(ok: false,
          msg: "parent was not a SimEngineError")
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type escaped simulate(): " & exc.msg)
    probeChan.send(outcome)

  proc probePlainDefectWithNilParentReraisesUnchanged() {.thread.} =
    ## Findings 17/18's other corner: `runSimulation`'s `except Defect`
    ## handler only recovers a Defect whose `.parent` is one of the three
    ## typed sim exceptions - a plain library Defect (`raiseAssert`,
    ## `.parent` nil) must fall through its `elif` chain unchanged and
    ## escape `simulate()` as itself, never reclassified as a
    ## `SimulationError`.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulate(seed = 14'u64):
        raiseAssert "plain defect from body, not sim-related"
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not run the body")
    except AssertionDefect:
      discard
    except SimulationError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "a nil-parent Defect was reclassified as SimulationError " &
             "kind " & $exc.kind)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type escaped simulate(): " & exc.msg)
    probeChan.send(outcome)

  proc probeDefectWithNonSimParentReraisesUnchanged() {.thread.} =
    ## The same fall-through branch's other half: a Defect whose
    ## `.parent` is non-nil but not one of `SimLedgerError`/
    ## `SimEngineError`/`SimBarrierError` - an ordinary `raiseAsDefect`
    ## envelope around an unrelated `CatchableError`, the shape a real
    ## non-sim `raiseAsDefect` call site (`chronos/internal/
    ## asyncengine.nim`'s own production uses) would produce even under
    ## simulation. Must also fall through unchanged.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulate(seed = 15'u64):
        let parentExc = newException(ValueError, "not a sim exception")
        raiseAsDefect(parentExc, "test: unrelated Defect envelope")
      outcome = ProbeOutcome(ok: false,
        msg: "simulate() did not run the body")
    except Defect as exc:
      if exc.parent.isNil or not (exc.parent of ValueError):
        outcome = ProbeOutcome(ok: false,
          msg: "the wrong parent survived the re-raise")
    except SimulationError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "a non-sim-parent Defect was reclassified as SimulationError " &
             "kind " & $exc.kind)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type escaped simulate(): " & exc.msg)
    probeChan.send(outcome)

  proc nextArgEvalSeed(): uint64 =
    inc argEvalCount
    900'u64 + argEvalCount.uint64

  proc probeSimulateEvaluatesSeedArgumentExactlyOnce() {.thread.} =
    ## R2-6: `simulate`'s `seed` template parameter is substituted at
    ## every occurrence in the expansion (attribution into
    ## `simulateCore` plus `RandomOracle(seed)`); a non-idempotent seed
    ## argument must still be evaluated exactly once.
    var outcome = ProbeOutcome(ok: true)
    argEvalCount = 0
    simulate(seed = nextArgEvalSeed()):
      discard
    if argEvalCount != 1:
      outcome = ProbeOutcome(ok: false,
        msg: "seed argument evaluated " & $argEvalCount &
             " times, expected 1")
    probeChan.send(outcome)

  proc nextArgEvalTracePath(path: string): string =
    inc argEvalCount
    path

  proc probeSimulateReplayEvaluatesTracePathArgumentExactlyOnce() {.thread.} =
    ## R2-6: `simulateReplay`'s `tracePath` template parameter is
    ## substituted at every occurrence in the expansion (the seed-
    ## attribution read plus `ReplayOracle(tracePath)`); a non-
    ## idempotent `tracePath` argument must still be evaluated exactly
    ## once, and the trace file itself read exactly once.
    var outcome = ProbeOutcome(ok: true)
    let seed = 950'u64
    let tracePath = simTracePath(seed)
    try:
      simulate(seed = seed):
        discard
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "recording run unexpectedly failed: " & exc.msg)
    if outcome.ok:
      argEvalCount = 0
      try:
        simulateReplay(nextArgEvalTracePath(tracePath)):
          discard
      except CatchableError as exc:
        outcome = ProbeOutcome(ok: false,
          msg: "replay unexpectedly failed: " & exc.msg)
      if outcome.ok and argEvalCount != 1:
        outcome = ProbeOutcome(ok: false,
          msg: "tracePath argument evaluated " & $argEvalCount &
               " times, expected 1")
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

  suite "SimBarrierError classification":
    test "a barrier hit propagated from the body is classified BarrierHit":
      let outcome = runProbe(probeBodyBarrierHitClassifiedAsBarrierHit)
      checkpoint outcome.msg
      check outcome.ok

    test "a Defect-enveloped barrier hit is classified BarrierHit":
      let outcome = runProbe(probeDefectEnvelopedBarrierHitClassifiedAsBarrierHit)
      checkpoint outcome.msg
      check outcome.ok

    test "a sweep classifies every barriering seed as BarrierHit":
      let outcome = runProbe(probeSweepClassifiesBarrierHitByKind)
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

  suite "simulateWithOracle":
    test "a scripted oracle driven through the harness keeps every guarantee":
      let outcome = runProbe(probeScriptedOracleThroughHarnessKeepsGuarantees)
      checkpoint outcome.msg
      check outcome.ok

    test "an oracle deferring all deliverable work with no fallback is classified OracleDeferral":
      let outcome = runProbe(probeOracleDeferralThroughHarnessClassifiedAsOracleDeferral)
      checkpoint outcome.msg
      check outcome.ok

  suite "simulateReplay":
    test "an identical body replays clean, a divergent one is a typed SimulationError":
      let outcome = runProbe(probeReplayReproducesRecordedRunAndDetectsDivergence)
      checkpoint outcome.msg
      check outcome.ok

  suite "template argument evaluation (R2-6)":
    test "simulate evaluates a non-idempotent seed argument exactly once":
      let outcome = runProbe(probeSimulateEvaluatesSeedArgumentExactlyOnce)
      checkpoint outcome.msg
      check outcome.ok

    test "simulateReplay evaluates a non-idempotent tracePath argument exactly once":
      let outcome = runProbe(probeSimulateReplayEvaluatesTracePathArgumentExactlyOnce)
      checkpoint outcome.msg
      check outcome.ok

  suite "budget/ledger matrix":
    test "sweepSeedsWithLedger classifies a planted violation by SimSeedFailureKind":
      let outcome = runProbe(probeSweepWithLedgerClassifiesViolatingSeedsByKind)
      checkpoint outcome.msg
      check outcome.ok

    test "simulateWithBudgetAndLedger compiles and runs":
      let outcome = runProbe(probeBudgetAndLedgerCombinationCompilesAndRuns)
      checkpoint outcome.msg
      check outcome.ok

  suite "Defect envelope recovery":
    test "a Defect-enveloped SimEngineError recovers its own SimFailureKind":
      let outcome = runProbe(probeDefectEnvelopedEngineErrorRecoversItsKind)
      checkpoint outcome.msg
      check outcome.ok

    test "a plain Defect with a nil parent escapes simulate() unchanged":
      let outcome = runProbe(probePlainDefectWithNilParentReraisesUnchanged)
      checkpoint outcome.msg
      check outcome.ok

    test "a Defect with a non-sim parent escapes simulate() unchanged":
      let outcome = runProbe(probeDefectWithNonSimParentReraisesUnchanged)
      checkpoint outcome.msg
      check outcome.ok
