#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for the discrete-event virtual clock's `decideTime` choice point
## and the sim poll iteration's quiescence detection
## (`chronos/internal/simengine.nim`'s `simDecideTimeAdvance` and, under
## `-d:chronosSimulation`, its wiring into `chronos/internal/asyncengine.nim`'s
## `poll()` via the `pollSelectTouchpoint` extension point).

import unittest2
import std/strutils
import results
import ../chronos/timer
import ../chronos/internal/simengine

{.used.}

suite "sim decideTime advance":
  test "the default oracle advances to the earliest armed deadline":
    let state = newSimEngineState()
    let earliest = Moment.init(100, Nanosecond)
    let later = Moment.init(200, Nanosecond)
    let curTime = Moment.init(0, Nanosecond)
    let advanceTo = state.simDecideTimeAdvance(@[earliest, later], curTime)
    check advanceTo == earliest

  test "a scripted oracle can override the default rule":
    let oracle = newSimOracle(proc(cp: TimeAdvancePoint):
        Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
      ok(TimeDecision(advanceTo: cp.armed[^1])))
    let state = newSimEngineState(oracle = oracle)
    let earliest = Moment.init(100, Nanosecond)
    let latest = Moment.init(300, Nanosecond)
    let curTime = Moment.init(0, Nanosecond)
    let advanceTo = state.simDecideTimeAdvance(@[earliest, latest], curTime)
    check advanceTo == latest

  test "an advance earlier than the earliest armed deadline is a violation":
    let oracle = newSimOracle(proc(cp: TimeAdvancePoint):
        Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
      ok(TimeDecision(advanceTo: Moment.init(50, Nanosecond))))
    let state = newSimEngineState(oracle = oracle)
    let armed = Moment.init(100, Nanosecond)
    let curTime = Moment.init(0, Nanosecond)
    expect AssertionDefect:
      discard state.simDecideTimeAdvance(@[armed], curTime)

  test "an advance earlier than the current virtual clock is a violation":
    let oracle = newSimOracle(proc(cp: TimeAdvancePoint):
        Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
      ok(TimeDecision(advanceTo: cp.armed[0])))
    let state = newSimEngineState(oracle = oracle)
    let armed = Moment.init(100, Nanosecond)
    let curTime = Moment.init(150, Nanosecond)
    expect AssertionDefect:
      discard state.simDecideTimeAdvance(@[armed], curTime)

  test "an oracle error is reported, not silently accepted":
    let oracle = newSimOracle(proc(cp: TimeAdvancePoint):
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
