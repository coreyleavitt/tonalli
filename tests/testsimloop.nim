#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for the discrete-event virtual clock's `decideTime` choice point,
## the sim event set's `decideBatch` choice point, and the sim poll
## iteration's quiescence detection
## (`chronos/internal/simengine.nim`'s `simDecideTimeAdvance`/
## `simDecideBatch`/`simDeliverableEvents` and, under
## `-d:chronosSimulation`, their wiring into
## `chronos/internal/asyncengine.nim`'s `poll()` via the
## `pollSelectTouchpoint` extension point).

import unittest2
import std/strutils
import results
import ../chronos/timer
import ../chronos/futures
import ../chronos/internal/simengine

{.used.}

proc passthroughDecideBatch(cp: SelectBatchPoint):
    Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
  ## Shared stub for tests exercising only `decideTime`: delivers
  ## whatever is deliverable, in the order given, so `decideBatch` never
  ## interferes with the scenario under test.
  var order = newSeq[SimEventId](cp.deliverable.len)
  for i, ev in cp.deliverable:
    order[i] = ev.id
  ok(BatchDecision(order: order))

suite "sim decideTime advance":
  test "the default oracle advances to the earliest armed deadline":
    let state = newSimEngineState()
    let earliest = Moment.init(100, Nanosecond)
    let later = Moment.init(200, Nanosecond)
    let curTime = Moment.init(0, Nanosecond)
    let advanceTo = state.simDecideTimeAdvance(@[earliest, later], curTime)
    check advanceTo == earliest

  test "a scripted oracle can override the default rule":
    let oracle = newSimOracle(passthroughDecideBatch, defaultDecideIo, proc(cp: TimeAdvancePoint):
        Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
      ok(TimeDecision(advanceTo: cp.armed[^1])))
    let state = newSimEngineState(oracle = oracle)
    let earliest = Moment.init(100, Nanosecond)
    let latest = Moment.init(300, Nanosecond)
    let curTime = Moment.init(0, Nanosecond)
    let advanceTo = state.simDecideTimeAdvance(@[earliest, latest], curTime)
    check advanceTo == latest

  test "an advance earlier than the earliest armed deadline is a violation":
    let oracle = newSimOracle(passthroughDecideBatch, defaultDecideIo, proc(cp: TimeAdvancePoint):
        Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
      ok(TimeDecision(advanceTo: Moment.init(50, Nanosecond))))
    let state = newSimEngineState(oracle = oracle)
    let armed = Moment.init(100, Nanosecond)
    let curTime = Moment.init(0, Nanosecond)
    expect AssertionDefect:
      discard state.simDecideTimeAdvance(@[armed], curTime)

  test "an advance earlier than the current virtual clock is a violation":
    let oracle = newSimOracle(passthroughDecideBatch, defaultDecideIo, proc(cp: TimeAdvancePoint):
        Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
      ok(TimeDecision(advanceTo: cp.armed[0])))
    let state = newSimEngineState(oracle = oracle)
    let armed = Moment.init(100, Nanosecond)
    let curTime = Moment.init(150, Nanosecond)
    expect AssertionDefect:
      discard state.simDecideTimeAdvance(@[armed], curTime)

  test "an oracle error is reported, not silently accepted":
    let oracle = newSimOracle(passthroughDecideBatch, defaultDecideIo, proc(cp: TimeAdvancePoint):
        Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
      err(SimOracleError(msg: "scripted failure")))
    let state = newSimEngineState(oracle = oracle)
    let armed = Moment.init(100, Nanosecond)
    let curTime = Moment.init(0, Nanosecond)
    try:
      discard state.simDecideTimeAdvance(@[armed], curTime)
      check false
    except AssertionDefect as exc:
      check "scripted failure" in exc.msg

suite "sim decideBatch and the sim event set":
  test "the default oracle delivers deliverable ids in the given order":
    let state = newSimEngineState()
    let evA = SimEvent(id: SimEventId(3), kind: SimEventKind.Readiness,
                        source: SimEndpointId(0))
    let evB = SimEvent(id: SimEventId(7), kind: SimEventKind.Readiness,
                        source: SimEndpointId(1))
    let decision = state.simDecideBatch(@[evA, evB])
    check decision.order == @[SimEventId(3), SimEventId(7)]

  test "an id absent from deliverable is a structured failure":
    let oracle = newSimOracle(
      proc(cp: SelectBatchPoint): Result[BatchDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(BatchDecision(order: @[SimEventId(999)])),
      defaultDecideIo,
      proc(cp: TimeAdvancePoint): Result[TimeDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(TimeDecision(advanceTo: cp.armed[0])))
    let state = newSimEngineState(oracle = oracle)
    let ev = SimEvent(id: SimEventId(1), kind: SimEventKind.Readiness,
                       source: SimEndpointId(0))
    try:
      discard state.simDecideBatch(@[ev])
      check false
    except AssertionDefect as exc:
      check "not in deliverable" in exc.msg

  test "the same id named twice is a structured failure":
    let oracle = newSimOracle(
      proc(cp: SelectBatchPoint): Result[BatchDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(BatchDecision(order: @[cp.deliverable[0].id, cp.deliverable[0].id])),
      defaultDecideIo,
      proc(cp: TimeAdvancePoint): Result[TimeDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(TimeDecision(advanceTo: cp.armed[0])))
    let state = newSimEngineState(oracle = oracle)
    let ev = SimEvent(id: SimEventId(1), kind: SimEventKind.Readiness,
                       source: SimEndpointId(0))
    try:
      discard state.simDecideBatch(@[ev])
      check false
    except AssertionDefect as exc:
      check "more than once" in exc.msg

  test "deliverable is sorted by id across the readiness and arrival queues":
    let state = newSimEngineState()
    # Scheduling the arrival first mints it the smaller id; marking the
    # reader ready afterward mints a larger one. `simDeliverableEvents`
    # concatenates the readiness queue before the arrival queue
    # internally, so this only comes out in id order if the sort is
    # real - the tripwire this test exists to pin (RFC 0003 3.3's
    # stable-alternative-order house rule).
    let arrivalId = state.simScheduleArrival()
    state.simSetReaderInterest(7, bareCallback(proc(arg: pointer)
      {.gcsafe, raises: [].} = discard))
    let readyId = state.simMarkReady(7, SimReadyDirection.Read)
    let deliverable = state.simDeliverableEvents()
    check deliverable.len == 2
    check deliverable[0].id == arrivalId
    check deliverable[1].id == readyId

when defined(chronosSimulation) and compileOption("threads"):
  ## Every probe below drives a fresh sim dispatcher's `poll()`/`waitFor`
  ## from its own OS thread, the same isolation `tests/testsimengine.nim`
  ## uses: `setThreadDispatcher` must never touch this binary's shared
  ## real per-thread dispatcher.
  import std/monotimes
  import std/times except seconds, milliseconds
  import ../chronos
  import ../chronos/internal/simclock

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

  proc decideTimeEarliest(cp: TimeAdvancePoint):
      Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
    ok(TimeDecision(advanceTo: cp.armed[0]))

  proc probeEqualDeadlineOrder() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    activateSimClock()
    var order: seq[string]
    let due = Moment.now()
    template arm(label: string) =
      discard setTimer(due, proc(udata: pointer) {.gcsafe, raises: [].} =
        order.add(label))
    arm("A")
    arm("B")
    arm("C")
    arm("D")
    poll()
    if order != @["A", "C", "B", "D"]:
      outcome = ProbeOutcome(ok: false, msg: "fire order was " & $order)
    deactivateSimClock()
    probeChan.send(outcome)

  proc probeSleepChain() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    activateSimClock()
    var fireOrder: seq[int]
    proc body() {.async.} =
      for i in 0 ..< 10:
        await sleepAsync(1.seconds)
        fireOrder.add(i)
    let wallStart = getMonoTime()
    waitFor body()
    let wallElapsedMs = (getMonoTime() - wallStart).inMilliseconds
    if fireOrder != @[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]:
      outcome = ProbeOutcome(ok: false, msg: "fire order was " & $fireOrder)
    elif wallElapsedMs >= 2000:
      outcome = ProbeOutcome(ok: false,
        msg: "wall clock elapsed " & $wallElapsedMs &
             "ms for 10s of virtual sleep")
    deactivateSimClock()
    probeChan.send(outcome)

  proc probeDeadlock() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    activateSimClock()
    let fut = newFuture[void]("neverCompletes")
    let wallStart = getMonoTime()
    try:
      waitFor fut
      outcome = ProbeOutcome(ok: false,
        msg: "waitFor returned without the future completing")
    except AssertionDefect as exc:
      let wallElapsedMs = (getMonoTime() - wallStart).inMilliseconds
      if "deadlock: no runnable work" notin exc.msg:
        outcome = ProbeOutcome(ok: false, msg: "wrong message: " & exc.msg)
      elif wallElapsedMs >= 2000:
        outcome = ProbeOutcome(ok: false,
          msg: "deadlock took " & $wallElapsedMs & "ms to surface")
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & exc.msg)
    deactivateSimClock()
    probeChan.send(outcome)

  proc probeReadinessOrder() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    var fireOrder: seq[int]
    proc decideBatchReverse(cp: SelectBatchPoint):
        Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
      var order = newSeq[SimEventId](cp.deliverable.len)
      for i, ev in cp.deliverable:
        order[cp.deliverable.len - 1 - i] = ev.id
      ok(BatchDecision(order: order))
    let disp = newSimDispatcher(
      oracle = newSimOracle(decideBatchReverse, defaultDecideIo, decideTimeEarliest))
    setThreadDispatcher(disp)
    let fdA = disp.mintSimFd()
    let fdB = disp.mintSimFd()
    discard addReader2(fdA, proc(arg: pointer) {.gcsafe, raises: [].} =
      fireOrder.add(1))
    discard addReader2(fdB, proc(arg: pointer) {.gcsafe, raises: [].} =
      fireOrder.add(2))
    discard disp.simMarkReady(fdA, SimReadyDirection.Read)
    discard disp.simMarkReady(fdB, SimReadyDirection.Read)
    poll()
    if fireOrder != @[2, 1]:
      outcome = ProbeOutcome(ok: false, msg: "fire order was " & $fireOrder)
    probeChan.send(outcome)

  proc probeIdlerParity() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    var idlerFired = false
    callIdle(proc(arg: pointer) {.gcsafe, raises: [].} = idlerFired = true)
    poll()
    if not idlerFired:
      outcome = ProbeOutcome(ok: false,
        msg: "idler did not fire on an empty batch")
    probeChan.send(outcome)

  proc probeArrivalDrain() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let disp = newSimDispatcher()
    setThreadDispatcher(disp)
    discard disp.simScheduleArrival()
    try:
      poll()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "poll() did not drain the scripted arrival: " & exc.msg)
    probeChan.send(outcome)

  proc probeOracleDeferralNotDeadlock() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    proc decideBatchDefer(cp: SelectBatchPoint):
        Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
      ok(BatchDecision(order: @[]))
    let disp = newSimDispatcher(
      oracle = newSimOracle(decideBatchDefer, defaultDecideIo, decideTimeEarliest))
    setThreadDispatcher(disp)
    let fd = disp.mintSimFd()
    discard addReader2(fd, proc(arg: pointer) {.gcsafe, raises: [].} = discard)
    discard disp.simMarkReady(fd, SimReadyDirection.Read)
    try:
      poll()
      outcome = ProbeOutcome(ok: false, msg: "poll() did not fail")
    except AssertionDefect as exc:
      if "oracle deferred all deliverable work with no fallback" notin exc.msg:
        outcome = ProbeOutcome(ok: false, msg: "wrong message: " & exc.msg)
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type: " & exc.msg)
    probeChan.send(outcome)

  suite "sim poll loop":
    test "equal-deadline timers pop in heap-derived order, not insertion order":
      let outcome = runProbe(probeEqualDeadlineOrder)
      checkpoint outcome.msg
      check outcome.ok

    test "a 10-sleep chain fires in order with bounded wall clock":
      let outcome = runProbe(probeSleepChain)
      checkpoint outcome.msg
      check outcome.ok

    test "a body awaiting a never-completed future fails immediately as deadlock":
      let outcome = runProbe(probeDeadlock)
      checkpoint outcome.msg
      check outcome.ok

    test "readiness-event delivery order follows scripted decisions":
      let outcome = runProbe(probeReadinessOrder)
      checkpoint outcome.msg
      check outcome.ok

    test "an empty batch triggers idlers exactly as count == 0 does today":
      let outcome = runProbe(probeIdlerParity)
      checkpoint outcome.msg
      check outcome.ok

    test "a scripted arrival batch drains through processThreadCallbacks":
      let outcome = runProbe(probeArrivalDrain)
      checkpoint outcome.msg
      check outcome.ok

    test "an oracle deferring all deliverable work with no fallback " &
        "fails distinctly from deadlock":
      let outcome = runProbe(probeOracleDeferralNotDeadlock)
      checkpoint outcome.msg
      check outcome.ok
