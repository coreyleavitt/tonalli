#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## The deterministic simulation substrate's public surface (RFC 0003
## 3.10): `simulate`, the single-run harness primitive that runs an
## async body on a fresh hermetic sim dispatcher and restores the
## thread's real dispatcher afterward, whatever the body's outcome.
##
## Re-exports `chronos/internal/simengine` (which itself re-exports
## `chronos/internal/simtrace`), so this is the one import a sim test
## needs beyond `chronos` itself: `SimOracle` and its choice-point/
## decision types, `newSimOracle`, `RandomOracle`, `ReplayOracle`,
## `SimBarrierError`, and the trace schema.

import std/[os, strutils]
import unittest2
import ../chronos
import ./internal/simengine
import ./internal/simclock

export simengine

type
  SimFailureKind* {.pure.} = enum
    ## What made a `simulate()` run fail (RFC 0003 3.8). `BodyError` is
    ## the async body's own exception; the rest classify the internal
    ## Defects `simDecideBatch`/`simDecideIo`/`simDecideTimeAdvance` and
    ## the sim poll loop already raise for a protocol violation,
    ## quiescence, or an oracle deferring all deliverable work with no
    ## fallback (RFC 0003 3.5) - `simulate()` is the boundary that
    ## converts each from a Defect into this catchable, structured kind.
    BodyError
    Deadlock
    OracleDeferral
    ProtocolViolation
    DecisionBudgetExhausted
    TimeBudgetExhausted

  SimulationError* = object of CatchableError
    ## Raised by `simulate()` for any run failure, seed- and trace-
    ## attributed so a failing seed is a complete bug report (RFC 0003
    ## 3.8). `parent` (inherited from `Exception`) holds the original
    ## exception: the body's own error, or the converted internal Defect.
    kind*: SimFailureKind
    seed*: uint64
    tracePath*: string

const
  simulateDefaultDecisionBudget* = 10_000
    ## Generous default (RFC 0003 3.8): every oracle `decide*` call
    ## counts against it, so ordinary tests never come close.
  simulateDefaultTimeBudget* = seconds(3_600)
    ## Generous default: an hour of virtual time.

proc classifySimFailure(msg: string): SimFailureKind =
  if msg.startsWith("deadlock:"):
    SimFailureKind.Deadlock
  elif msg.startsWith("oracle deferred"):
    SimFailureKind.OracleDeferral
  elif msg.startsWith("livelock: decision budget"):
    SimFailureKind.DecisionBudgetExhausted
  elif msg.startsWith("livelock: virtual-time budget"):
    SimFailureKind.TimeBudgetExhausted
  else:
    SimFailureKind.ProtocolViolation

proc newSimulationError(kind: SimFailureKind, seed: uint64, tracePath, msg: string,
                         parent: ref Exception): ref SimulationError =
  result = newException(SimulationError,
    "simulation failed (seed=0x" & toLowerAscii(toHex(seed)) & "): " & msg)
  result.kind = kind
  result.seed = seed
  result.tracePath = tracePath
  result.parent = parent

proc simTracePath(seed: uint64): string =
  getTempDir() / "chronos-sim" / ("seed-" & $seed & ".ndjson")

proc runSimulation(seed: uint64, decisionBudget: int, timeBudget: Duration,
                    body: proc(): Future[void] {.gcsafe.}) =
  ## The harness core behind the `simulate` template (RFC 0003 3.8):
  ## saves the thread's current dispatcher without side effects,
  ## installs a fresh hermetic sim dispatcher seeded with `RandomOracle
  ## (seed)` and the given budgets, prints and flushes the seed banner,
  ## runs `body` to completion, and restores the saved dispatcher
  ## through the force path - unconditionally, whether `body` completed,
  ## the body raised, or the sim loop itself failed - so the original
  ## failure always survives and the calling thread's real dispatcher
  ## is always left intact.
  let savedDisp = getThreadDispatcherOrNil()
  let tracePath = simTracePath(seed)
  createDir(tracePath.parentDir)
  var writer = openSimTraceWriter(tracePath, seed = seed)
  let timeBudgetCutoffNanoseconds =
    simClockAnchorNanoseconds + timeBudget.nanoseconds
  let disp = newSimDispatcher(oracle = RandomOracle(seed),
    decisionBudget = decisionBudget, seed = seed, hasTimeBudget = true,
    timeBudgetCutoffNanoseconds = timeBudgetCutoffNanoseconds)
  disp.simAttachTraceWriter(addr writer)

  stdout.writeLine("[chronos-sim] seed=" & $seed & " trace=" & tracePath)
  stdout.flushFile()

  # Force path both ways (not only on restore, below): under the
  # default non-strict-reentrancy mode, any constructed-or-polled
  # dispatcher permanently carries the sentinel callback, so
  # `savedDisp.callbacks.len` is 1, never 0.
  forceSetThreadDispatcher(disp)
  activateSimClock()

  var failure: ref SimulationError = nil
  try:
    waitFor body()
  except AssertionDefect as exc:
    failure = newSimulationError(classifySimFailure(exc.msg), seed, tracePath,
                                  exc.msg, exc)
  except CatchableError as exc:
    failure = newSimulationError(SimFailureKind.BodyError, seed, tracePath,
                                  exc.msg, exc)
  finally:
    deactivateSimClock()
    disp.simAttachTraceWriter(nil)
    forceSetThreadDispatcher(savedDisp)
    writer.close()

  if failure != nil:
    raise failure

template simulate*(seed: uint64, body: untyped): untyped =
  ## Runs `body` (async code) to completion on a fresh, hermetic
  ## simulated dispatcher driven by `RandomOracle(seed)`, then restores
  ## the calling thread's real dispatcher - even if `body` raises or
  ## the simulation itself fails. A run that exceeds the default
  ## decision/time budget (RFC 0003 3.8), deadlocks, or hits an oracle/
  ## protocol violation raises `SimulationError`, and so does a raising
  ## `body` (unwrapped as `.parent`). See `simulateWithBudget` to
  ## override the budgets.
  runSimulation(seed, simulateDefaultDecisionBudget, simulateDefaultTimeBudget,
    proc() {.async, gcsafe.} =
      body)

template simulateWithBudget*(seed: uint64, decisionBudget: int,
                              timeBudget: Duration, body: untyped): untyped =
  ## As `simulate`, with `decisionBudget`/`timeBudget` overriding the
  ## defaults - the bounds a livelock trips at (RFC 0003 3.8). A
  ## separate template rather than an overload of `simulate`: with both
  ## sharing a name, resolving a call to either miscompiles `await` in
  ## `body` (reproduced standalone against the Nim 2.2.10 toolchain;
  ## not specific to this module).
  runSimulation(seed, decisionBudget, timeBudget,
    proc() {.async, gcsafe.} =
      body)

type
  SimSeedOutcome* = object
    ## One seed's verdict from `sweepSeeds`/`collectSweepSeeds` (RFC 0003
    ## 3.8): every seed in the swept range gets exactly one of these, in
    ## seed order, whether it passed or failed - the sweep never stops
    ## at the first failure, so a multi-seed bug never hides its
    ## siblings. A value the aggregator produces, never parsed back out
    ## of a message string.
    seed*: uint64
    tracePath*: string
    case passed*: bool
    of true:
      discard
    of false:
      kind*: SimFailureKind
      msg*: string

proc runSweepSeed(seed: uint64, decisionBudget: int, timeBudget: Duration,
                   body: proc(): Future[void] {.gcsafe.}): SimSeedOutcome =
  ## One seed of a sweep, `simulate`'s failure-to-outcome conversion
  ## instead of a raised `SimulationError`: `collectSweepSeeds` is the
  ## loop this drives, one call per seed.
  try:
    runSimulation(seed, decisionBudget, timeBudget, body)
    SimSeedOutcome(seed: seed, tracePath: simTracePath(seed), passed: true)
  except SimulationError as exc:
    SimSeedOutcome(seed: seed, tracePath: exc.tracePath, passed: false,
                    kind: exc.kind, msg: exc.msg)

proc collectSweepSeeds*(seeds: Slice[uint64], decisionBudget: int,
                         timeBudget: Duration,
                         body: proc(): Future[void] {.gcsafe.}):
    seq[SimSeedOutcome] =
  ## The aggregation loop behind `sweepSeeds`/`sweepSeedsWithBudget`,
  ## exposed on its own (RFC 0003 3.8): runs `body` once per seed in
  ## `seeds`, every seed regardless of its siblings' outcomes, and
  ## returns every `SimSeedOutcome` in seed order. Unlike the
  ## `sweepSeeds` templates, this never touches `unittest2` - the
  ## aggregate verdict is the caller's to report however it chooses
  ## (`sweepSeeds` reports it the `checkLeaks` way; a caller wanting a
  ## different report, or none, calls this directly).
  for seed in seeds:
    result.add runSweepSeed(seed, decisionBudget, timeBudget, body)

proc reportSweep(outcomes: seq[SimSeedOutcome]) =
  ## The `checkLeaks` idiom (`chronos/unittest2/asynctests.nim`): a
  ## `checkpoint` per failing seed, so a green sweep of a hundred seeds
  ## stays quiet, and one `check` at the end so the enclosing test fails
  ## once - never once per seed - when any seed did (RFC 0003 3.8).
  var failedCount = 0
  for outcome in outcomes:
    if not outcome.passed:
      inc failedCount
      checkpoint "[chronos-sim] seed=0x" & toLowerAscii(toHex(outcome.seed)) &
        " FAILED (" & $outcome.kind & "): " & outcome.msg &
        " trace=" & outcome.tracePath
  check failedCount == 0

template sweepSeeds*(seeds: Slice[uint64], body: untyped): seq[SimSeedOutcome] =
  ## Runs `body` (async code, as `simulate`'s) once per seed in `seeds`
  ## on its own fresh hermetic sim dispatcher, collecting every seed's
  ## `SimSeedOutcome` and reporting the aggregate the `checkLeaks` way
  ## (RFC 0003 3.8): every failing seed's seed, kind, message, and trace
  ## path via `checkpoint`, then one `check` failing the enclosing test
  ## if any seed failed. See `sweepSeedsWithBudget` to override the
  ## per-seed budgets, and `collectSweepSeeds` to aggregate without the
  ## `unittest2` reporting.
  sweepSeedsWithBudget(seeds, simulateDefaultDecisionBudget,
                        simulateDefaultTimeBudget, body)

template sweepSeedsWithBudget*(seeds: Slice[uint64], decisionBudget: int,
                                timeBudget: Duration,
                                body: untyped): seq[SimSeedOutcome] =
  ## As `sweepSeeds`, with `decisionBudget`/`timeBudget` overriding the
  ## defaults for every seed in the sweep. A separate template rather
  ## than an overload of `sweepSeeds`, the same `await`-miscompiles
  ## reason `simulateWithBudget` is separate from `simulate`.
  let sweepOutcomes = collectSweepSeeds(seeds, decisionBudget, timeBudget,
    proc(): Future[void] {.async, gcsafe.} =
      body)
  reportSweep(sweepOutcomes)
  sweepOutcomes
