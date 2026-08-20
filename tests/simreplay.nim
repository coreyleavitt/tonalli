#                  Tonalli Test Suite
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## `nimble replay <fixture-name> <trace-path>` -
## replays a downloaded failing-seed trace artifact against the named
## fixture body from `tests/simfixtures.nim`, so a CI sweep failure
## reproduces locally without hand-copying the body out of the suite it
## came from. `runReplay` is the shared dispatch every caller (this
## file's own `main` below, and `tests/testsimreplay.nim`) drives - only
## `main` touches argv, stdout/stderr framing, and the exit code.

import std/os
import ../tonalli
import ../tonalli/simulation
import ../tonalli/contextvars
import ../tonalli/streams/asyncstream
import ./simfixtures

type
  ReplayStatus* = enum
    UnknownFixture
    TraceUnreadable
    Passed
    FailureReproduced

  ReplayOutcome* = object
    status*: ReplayStatus
    kind*: string
      ## The reproduced failure's `SimFailureKind` name, or `"Ledger"`
      ## for a `SimLedgerError` - set only when
      ## `status == FailureReproduced`.
    message*: string

proc knownFixturesText*(): string =
  result = "known fixtures:"
  for name in fixtureNames:
    result.add "\n  " & name

proc runReplay*(name, tracePath: string): ReplayOutcome =
  ## Dispatches `name` to its registered fixture and replays
  ## `tracePath` against it. Never raises: every outcome, including an
  ## unknown name or an unreadable trace, comes back as a `ReplayOutcome`
  ## for the caller to report.
  if name notin fixtureNames:
    return ReplayOutcome(status: UnknownFixture,
      message: "unknown fixture: " & name)
  if not fileExists(tracePath):
    return ReplayOutcome(status: TraceUnreadable,
      message: "trace file not found: " & tracePath)
  try:
    case name
    of "callbackqueue-callsoon-fifo-order":
      simulateReplay(tracePath):
        callbackqueueCallSoonFifoOrderFixture()
    of "callbackqueue-idler-fires-on-empty-batch":
      simulateReplay(tracePath):
        callbackqueueIdlerFiresOnEmptyBatchFixture()
    of "contextvars-binding-survives-sequential-awaits":
      simulateReplay(tracePath):
        contextvarsBindingSurvivesSequentialAwaitsFixture()
    of "contextvars-concurrent-tasks-stay-isolated":
      simulateReplay(tracePath):
        contextvarsConcurrentTasksStayIsolatedFixture()
    of "contextvars-child-inherits-no-leak-back":
      simulateReplay(tracePath):
        contextvarsChildInheritsNoLeakBackFixture()
    of "contextvars-exception-across-await-reverts-binding":
      simulateReplay(tracePath):
        contextvarsExceptionAcrossAwaitRevertsBindingFixture()
    of "contextvars-cancelled-error-via-timer-reverts-binding":
      simulateReplay(tracePath):
        contextvarsCancelledErrorViaTimerRevertsBindingFixture()
    of "simnet-pipelined-echo-under-partial-completions":
      simulateReplay(tracePath):
        simnetPipelinedEchoUnderPartialCompletionsFixture()
    of "simulation-sweep-runs-every-seed-empty-body":
      simulateReplay(tracePath):
        simulationSweepRunsEverySeedEmptyBodyFixture()
    of "simulation-sweep-with-ledger-classifies-violating-seed":
      resetSimulationLedgerFixtureForReplay()
      simulateReplayWith(tracePath, simulationLedgerFixtureOpts()):
        simulationSweepWithLedgerClassifiesViolatingSeedFixture()
    else:
      doAssert false, "unreachable: name already checked against fixtureNames"
    ReplayOutcome(status: Passed,
      message: "fixture=" & name & " trace=" & tracePath)
  except SimulationError as exc:
    ReplayOutcome(status: FailureReproduced, kind: $exc.kind, message: exc.msg)
  except SimLedgerError as exc:
    ReplayOutcome(status: FailureReproduced, kind: "Ledger", message: exc.msg)
  except IOError as exc:
    ReplayOutcome(status: TraceUnreadable, message: exc.msg)
  except SimTraceReadError as exc:
    ReplayOutcome(status: TraceUnreadable, message: exc.msg)

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    stderr.writeLine "usage: nimble replay <fixture-name> <trace-path>"
    stderr.writeLine knownFixturesText()
    quit(1)

  let outcome = runReplay(args[0], args[1])
  case outcome.status
  of UnknownFixture:
    stderr.writeLine "unknown fixture: " & args[0]
    stderr.writeLine knownFixturesText()
    quit(1)
  of TraceUnreadable:
    stderr.writeLine "trace error: " & outcome.message
    quit(1)
  of Passed:
    echo "REPLAY_OK fixture=" & args[0] & " trace=" & args[1]
    quit(0)
  of FailureReproduced:
    echo "REPLAY_FAILURE_REPRODUCED fixture=" & args[0] & " kind=" &
      outcome.kind & " msg=" & outcome.message
    quit(0)
