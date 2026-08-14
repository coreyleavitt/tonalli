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
