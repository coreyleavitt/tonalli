#                  Tonalli Test Suite
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## Tests for `tests/simreplay.nim`'s `runReplay` dispatch: a downloaded
## failing-seed trace replays through its named fixture and reproduces
## the same failure, and an unknown fixture name
## or an unreadable trace path comes back as a clean typed outcome
## rather than a raise.

import unittest2

{.used.}

when defined(chronosSimulation) and compileOption("threads"):
  ## Every probe below drives `runReplay` (`simulateReplay`/
  ## `simulateReplayWith` underneath) from its own OS thread, the same
  ## isolation `tests/testsimulation.nim` uses.
  import std/os
  import std/strutils
  import ../tonalli
  import ../tonalli/simulation
  import ./simfixtures
  import ./simreplay

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

  proc probeReplayReproducesAKnownFailingSeed() {.thread.} =
    ## Produces a genuine ledger-violation trace the same way
    ## `tests/testsimulation.nim`'s own fixture does (`resetSimulation-
    ## LedgerFixtureForReplay`'s docstring), then drives `runReplay`
    ## against it - the failure must reproduce, classified `Ledger`,
    ## carrying the same law name the direct run's own exception did.
    var outcome = ProbeOutcome(ok: true)
    const seed = 0x5EED'u64
    resetSimulationLedgerFixtureForReplay()
    var raised = false
    try:
      simulateWith(seed, simulationLedgerFixtureOpts()):
        simulationSweepWithLedgerClassifiesViolatingSeedFixture()
    except SimLedgerError:
      raised = true
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "recording run raised the wrong exception type: " & exc.msg)

    if outcome.ok and not raised:
      outcome = ProbeOutcome(ok: false,
        msg: "recording run did not hit the planted ledger violation")

    if outcome.ok:
      let tracePath = simTracePath(seed)
      let replayed = runReplay(
        "simulation-sweep-with-ledger-classifies-violating-seed", tracePath)
      if replayed.status != FailureReproduced:
        outcome = ProbeOutcome(ok: false,
          msg: "replay did not reproduce the failure, status=" &
            $replayed.status)
      elif replayed.kind != "Ledger":
        outcome = ProbeOutcome(ok: false,
          msg: "wrong kind reproduced: " & replayed.kind)
      elif "callback conservation" notin replayed.message:
        outcome = ProbeOutcome(ok: false,
          msg: "lost the law name: " & replayed.message)
    probeChan.send(outcome)

  proc probeReplayOfAPassingSeedReportsPassed() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    const seed = 0x5EED1'u64
    try:
      simulate(seed):
        callbackqueueCallSoonFifoOrderFixture()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "recording run unexpectedly failed: " & exc.msg)

    if outcome.ok:
      let tracePath = simTracePath(seed)
      let replayed = runReplay("callbackqueue-callsoon-fifo-order", tracePath)
      if replayed.status != Passed:
        outcome = ProbeOutcome(ok: false,
          msg: "expected Passed, got status=" & $replayed.status &
            " msg=" & replayed.message)
    probeChan.send(outcome)

  proc probeUnknownFixtureNameReportsUnknown() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let replayed = runReplay("does-not-exist", "/nonexistent/trace.ndjson")
    if replayed.status != UnknownFixture:
      outcome = ProbeOutcome(ok: false,
        msg: "expected UnknownFixture, got status=" & $replayed.status)
    probeChan.send(outcome)

  proc probeMissingTracePathReportsTraceUnreadable() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let replayed = runReplay("callbackqueue-callsoon-fifo-order",
      "/nonexistent/trace.ndjson")
    if replayed.status != TraceUnreadable:
      outcome = ProbeOutcome(ok: false,
        msg: "expected TraceUnreadable, got status=" & $replayed.status)
    probeChan.send(outcome)

  proc probeMalformedTraceFileReportsTraceUnreadable() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let tracePath = getTempDir() / "chronos-sim-replay-malformed.ndjson"
    writeFile(tracePath, "")
    let replayed = runReplay("callbackqueue-callsoon-fifo-order", tracePath)
    removeFile(tracePath)
    if replayed.status != TraceUnreadable:
      outcome = ProbeOutcome(ok: false,
        msg: "expected TraceUnreadable, got status=" & $replayed.status)
    probeChan.send(outcome)

  proc probeFixtureNamesEnumerateEveryRegisteredFixture() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    if fixtureNames.len != 10:
      outcome = ProbeOutcome(ok: false,
        msg: "expected 10 registered fixtures, got " & $fixtureNames.len)
    for name in fixtureNames:
      if name notin knownFixturesText():
        outcome = ProbeOutcome(ok: false,
          msg: "fixture " & name & " missing from knownFixturesText()")
    probeChan.send(outcome)

  suite "simreplay: runReplay dispatch":
    test "a downloaded failing-seed trace reproduces the same failure":
      let outcome = runProbe(probeReplayReproducesAKnownFailingSeed)
      checkpoint outcome.msg
      check outcome.ok

    test "replaying a passing seed's trace reports Passed":
      let outcome = runProbe(probeReplayOfAPassingSeedReportsPassed)
      checkpoint outcome.msg
      check outcome.ok

    test "an unknown fixture name reports UnknownFixture":
      let outcome = runProbe(probeUnknownFixtureNameReportsUnknown)
      checkpoint outcome.msg
      check outcome.ok

    test "a missing trace path reports TraceUnreadable":
      let outcome = runProbe(probeMissingTracePathReportsTraceUnreadable)
      checkpoint outcome.msg
      check outcome.ok

    test "a malformed trace file reports TraceUnreadable":
      let outcome = runProbe(probeMalformedTraceFileReportsTraceUnreadable)
      checkpoint outcome.msg
      check outcome.ok

    test "fixtureNames enumerates every registered fixture":
      let outcome = runProbe(probeFixtureNamesEnumerateEveryRegisteredFixture)
      checkpoint outcome.msg
      check outcome.ok
