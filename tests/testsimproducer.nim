#                  Tonalli Test Suite
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## Tests for `chronos/simulation.nim`'s `simProducer` (RFC 0003 3.6,
## slice S13): arrival actors, the coalescing constraint, and the
## headline reproduction this slice supplies - the literal cross-thread
## `testsoon.nim` shape (pre-upstream-#703: a bool latch checked once,
## no loop) now reachable through a real `simProducer`/`Arrival`
## instead of `tests/testsimulation.nim`'s S9a readiness-event stand-in
## (that fixture's own docstring records the literal repro as barred
## until this slice).

import unittest2
import std/strutils

{.used.}

when defined(chronosSimulation) and compileOption("threads"):
  ## Every probe runs on its own OS thread, the isolation
  ## `tests/testsimnet.nim` uses: `setThreadDispatcher`/the sim clock
  ## are thread-local, so each probe needs a dispatcher no earlier probe
  ## in the same binary has touched.
  import ../tonalli
  import ../tonalli/simulation
  import ../tonalli/internal/simclock

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

  proc setFlag(udata: pointer) {.nimcall, gcsafe, raises: [].} =
    cast[ptr bool](udata)[] = true

  proc incCounter(udata: pointer) {.nimcall, gcsafe, raises: [].} =
    inc cast[ptr int](udata)[]

  proc probeSinglePostDeliversAfterOnePoll() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    activateSimClock()

    proc body() {.async.} =
      var fired = false
      let producer = simProducer()
      producer.post(setFlag, addr fired)
      # `poll()` cannot be called directly from async code (illegal
      # `NestedPoll` effect, `tests/testcallbackqueue.nim`'s sweep
      # fixtures document the same workaround); yielding once drains
      # the already-scheduled arrival.
      await sleepAsync(0.milliseconds)
      if not fired:
        raise newException(ValueError,
          "producer's callback did not fire after one poll iteration")

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    deactivateSimClock()
    probeChan.send(outcome)

  proc probeTwoPostsBeforeAnyPollCoalesceIntoOneArrival() {.thread.} =
    ## RFC 0003 3.6's coalescing constraint, checked across the whole
    ## sweep (not one seed): two posts scripted before any poll
    ## iteration land in the same batch window and must both be
    ## observable after exactly one - the oracle has no freedom to
    ## split them into a schedule the real "one wakeup per batch of
    ## pushes" protocol could not produce.
    var outcome = ProbeOutcome(ok: true)

    proc coalescingBody() {.async.} =
      var count = 0
      let producer = simProducer()
      producer.post(incCounter, addr count)
      producer.post(incCounter, addr count)
      await sleepAsync(0.milliseconds)
      if count != 2:
        raise newException(ValueError,
          "coalescing violated: expected both posts to land in one " &
          "Arrival and fire after a single poll iteration, got count=" &
          $count)

    let outcomes = sweepSeeds(0'u64 .. 15'u64):
      await coalescingBody()
    for o in outcomes:
      if not o.passed:
        outcome = ProbeOutcome(ok: false,
          msg: "seed " & $o.seed & " failed (coalescing must hold for " &
               "every seed, it is not an oracle freedom): " & o.msg)
        break
    probeChan.send(outcome)

  proc pre703ArrivalFixtureBody() {.async.} =
    ## The literal cross-thread `testsoon.nim` shape (bool latch, no
    ## loop/join), reproduced through a real `simProducer` instead of
    ## `tests/testsimulation.nim`'s readiness-event stand-in: the
    ## producer's `Arrival` callback and an independent reaper race to
    ## be observed by a single, unrepeated check. If `decideBatch`
    ## delivers the reaper before the arrival in their shared batch,
    ## the reaper's single check runs before the producer's callback
    ## has fired - "the check passes off the first [completion], the
    ## test returns" - exactly the under-drain upstream #703 fixed by
    ## replacing a bool latch with a counting loop.
    let disp = getThreadDispatcher()
    var producerRan = false
    var reaperSawProducer = false
    let producer = simProducer()
    producer.post(setFlag, addr producerRan)
    let fdReaper = disp.mintSimFd()
    discard addReader2(fdReaper, proc(arg: pointer) {.gcsafe, raises: [].} =
      reaperSawProducer = producerRan)
    discard disp.simMarkReady(fdReaper, SimReadyDirection.Read)
    await sleepAsync(0.milliseconds)
    if not reaperSawProducer:
      raise newException(ValueError,
        "pre-#703 shape: the producer's arrival callback had not fired " &
        "by the time its single, unrepeated check ran")

  proc probePre703ShapeFailsUnderSweepAndReplaysViaReplayOracle() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    try:
      let outcomes = collectSweepSeeds(0'u64 .. 15'u64,
        simulateDefaultDecisionBudget, simulateDefaultTimeBudget,
        proc(): Future[void] {.async, gcsafe.} =
          await pre703ArrivalFixtureBody())
      var failingSeeds, passingSeeds: seq[uint64]
      var failingTrace = ""
      for o in outcomes:
        if o.passed:
          passingSeeds.add o.seed
        else:
          failingSeeds.add o.seed
          if failingTrace.len == 0:
            failingTrace = o.tracePath
      if failingSeeds.len == 0:
        outcome = ProbeOutcome(ok: false,
          msg: "no seed in 0..15 reproduced the race - fixture is not " &
               "exercising the order-dependent under-drain")
      elif passingSeeds.len == 0:
        outcome = ProbeOutcome(ok: false,
          msg: "every seed in 0..15 failed - the coalescing/order race " &
               "is not seed-dependent as expected")
      else:
        # Replay the first failing seed's own recorded trace through
        # ReplayOracle - independent of RandomOracle(seed) - RFC 0003
        # 3.7's payoff: a failing seed is a complete bug report.
        let replayDisp = newSimDispatcher(oracle = ReplayOracle(failingTrace))
        setThreadDispatcher(replayDisp)
        activateSimClock()
        try:
          waitFor pre703ArrivalFixtureBody()
          outcome = ProbeOutcome(ok: false,
            msg: "replay via ReplayOracle(" & failingTrace &
                 ") did not reproduce the failure")
        except ValueError as exc:
          if "pre-#703 shape" notin exc.msg:
            outcome = ProbeOutcome(ok: false,
              msg: "replay lost the original message: " & exc.msg)
        except CatchableError as exc:
          outcome = ProbeOutcome(ok: false,
            msg: "replay raised the wrong exception type: " & exc.msg)
        deactivateSimClock()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc fixedArrivalFixtureBody() {.async.} =
    ## The #703 fix shape: a counting loop instead of a single unguarded
    ## latch check - the reaper re-arms and re-checks across successive
    ## poll iterations until it has actually observed the producer's
    ## arrival, rather than trusting one batch's delivery order.
    let disp = getThreadDispatcher()
    var producerRan = false
    var reaperSawProducer = false
    let producer = simProducer()
    producer.post(setFlag, addr producerRan)
    let fdReaper = disp.mintSimFd()
    discard addReader2(fdReaper, proc(arg: pointer) {.gcsafe, raises: [].} =
      reaperSawProducer = producerRan)
    var iterations = 0
    while not reaperSawProducer:
      discard disp.simMarkReady(fdReaper, SimReadyDirection.Read)
      await sleepAsync(0.milliseconds)
      inc iterations
      if iterations > 100:
        raise newException(ValueError,
          "the #703 fix shape: reaper never observed the producer " &
          "after 100 iterations")

  proc probeFixedShapePassesEverySeedInSweep() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let outcomes = sweepSeeds(0'u64 .. 15'u64):
      await fixedArrivalFixtureBody()
    for o in outcomes:
      if not o.passed:
        outcome = ProbeOutcome(ok: false,
          msg: "seed " & $o.seed & " unexpectedly failed: " & o.msg)
        break
    probeChan.send(outcome)

  proc probeDrainPathHoldsUnderMixedBatchScheduling() {.thread.} =
    ## Drain-path coverage (RFC 0003 6, S13): three readiness events and
    ## one arrival (itself coalescing two producer posts) delivered
    ## together in one batch - every one must fire exactly once,
    ## regardless of `decideBatch`'s chosen order, proving
    ## `processThreadCallbacks`'s drain composes correctly with the
    ## ordinary readiness delivery path once they share a batch.
    var outcome = ProbeOutcome(ok: true)

    proc drainPathBody() {.async.} =
      let disp = getThreadDispatcher()
      var fireCounts = newSeq[int](5)
      for i in 0 ..< 3:
        let fd = disp.mintSimFd()
        let cb = proc(arg: pointer) {.gcsafe, raises: [].} =
          inc fireCounts[cast[int](arg)]
        discard addReader2(fd, cb, cast[pointer](i))
        discard disp.simMarkReady(fd, SimReadyDirection.Read)
      let producer = simProducer()
      producer.post(incCounter, addr fireCounts[3])
      producer.post(incCounter, addr fireCounts[4])
      await sleepAsync(0.milliseconds)
      for i, c in fireCounts:
        if c != 1:
          raise newException(ValueError,
            "drain-path: index " & $i & " fired " & $c & " times, " &
            "expected exactly 1")

    let outcomes = sweepSeeds(0'u64 .. 15'u64):
      await drainPathBody()
    for o in outcomes:
      if not o.passed:
        outcome = ProbeOutcome(ok: false,
          msg: "seed " & $o.seed & " failed: " & o.msg)
        break
    probeChan.send(outcome)

  suite "simProducer basics":
    test "post() delivers a single arrival after one poll iteration":
      let outcome = runProbe(probeSinglePostDeliversAfterOnePoll)
      checkpoint outcome.msg
      check outcome.ok

    test "two posts scripted before any poll coalesce into one Arrival, every seed":
      let outcome = runProbe(probeTwoPostsBeforeAnyPollCoalesceIntoOneArrival)
      checkpoint outcome.msg
      check outcome.ok

  suite "simProducer arrival races (RFC 0003 3.6, S13)":
    test "the pre-#703 shape fails under sweepSeeds and replays via ReplayOracle":
      let outcome = runProbe(probePre703ShapeFailsUnderSweepAndReplaysViaReplayOracle)
      checkpoint outcome.msg
      check outcome.ok

    test "the #703 fix shape passes every seed in the sweep":
      let outcome = runProbe(probeFixedShapePassesEverySeedInSweep)
      checkpoint outcome.msg
      check outcome.ok

  suite "drain-path coverage under scheduling variation":
    test "mixed readiness/arrival batches drain correctly for every seed":
      let outcome = runProbe(probeDrainPathHoldsUnderMixedBatchScheduling)
      checkpoint outcome.msg
      check outcome.ok
