#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Private mechanism backing the deterministic simulation substrate's
## dispatcher fork: the fd provenance table and its minting counter, the
## reserved barrier error code, `SimBarrierError`, and the discrete-event
## virtual clock's `decideTime` choice point (oracle interface, default
## advance rule, and the sim clock's sole write point).
##
## Imported by `chronos/internal/asyncengine.nim` under
## `-d:chronosSimulation`; this module never imports it back, so a
## simulated `Dispatcher`'s construction fork, provenance-guarded touch
## sites, and poll-loop extension points are the only consumers of the
## types below.

{.push raises: [], gcsafe.}

import std/sets
import results
import ../oserrno
import ../timer
import ./simclock

type
  SimBarrierError* = object of CatchableError
    ## Raised where a call site's signature can carry a typed error: a
    ## simulated dispatcher's fd provenance guard was crossed by a real
    ## fd, or a cross-thread entry point incompatible with simulation
    ## (`wake()`, `handle()`) was reached. Deliberately not a subtype of
    ## `AsyncError`, so an existing `except AsyncError` handler cannot
    ## silently swallow a hermeticity violation.

  TimeAdvancePoint* = object
    ## The discrete-event clock's decision point (RFC 0003 3.3):
    ## every deadline still armed in the timer heap, sorted earliest
    ## first, offered to the oracle when nothing else is runnable.
    armed*: seq[Moment]

  TimeDecision* = object
    advanceTo*: Moment
      ## Engine-validated: must be `>= armed[0]` and `>=` the current
      ## virtual clock. A violation is a structured failure (3.5), never
      ## a silent or backward clock write.

  SimOracleError* = object
    ## A value, not a `ref` exception, matching every in-tree `Result`
    ## error type (3.3's "Failure channel" note).
    msg*: string

  SimOracle* = object
    ## Fields private outside the sim modules; `newSimOracle` is the
    ## sole constructor (3.3's "Construction discipline"). Only the
    ## `decideTime` choice point is wired at this slice - `decideBatch`/
    ## `decideIo` are S4/S10's job, added the same additive-safe way.
    decideTimeImpl: proc(cp: TimeAdvancePoint):
      Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].}

  SimEngineState* = ref object
    ## The sim-mode run state carried on a simulated `Dispatcher`: the
    ## fd provenance table, populated at mint time and consulted by
    ## every registration/teardown touch site before it acts on a fd,
    ## the counter that mints it, and the oracle driving the virtual
    ## clock's `decideTime` choice point.
    endpoints: HashSet[int]
    nextFdValue: int
    oracle: SimOracle

const
  SimBarrierCode* = OSErrorCode(1_397_835_586'i32)
    ## Reserved `OSErrorCode`, outside every platform's errno range
    ## ("SIMB" packed as ASCII bytes). A provenance-guarded touch site
    ## under simulation returns `err(SimBarrierCode)` through its
    ## unchanged `Result` signature instead of touching a real fd or a
    ## nil selector.

proc newSimOracle*(decideTime: proc(cp: TimeAdvancePoint):
    Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].}): SimOracle =
  SimOracle(decideTimeImpl: decideTime)

proc defaultSimOracle*(): SimOracle =
  ## The default advance rule (S3): jump straight to the earliest armed
  ## deadline - the minimal-time-advance choice every scripted stub
  ## oracle before S5's `RandomOracle` falls back to unless it overrides
  ## `decideTime` itself.
  newSimOracle(proc(cp: TimeAdvancePoint):
      Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
    ok(TimeDecision(advanceTo: cp.armed[0])))

proc newSimEngineState*(startValue: int = 0,
                         oracle: SimOracle = defaultSimOracle()): SimEngineState =
  SimEngineState(endpoints: initHashSet[int](), nextFdValue: startValue,
                  oracle: oracle)

proc mintSimFd*(state: SimEngineState): int =
  ## Mints the next sim-owned fd-domain id and records it in the
  ## endpoint table. Skips `-1`, the representation shared by
  ## `osdefs.INVALID_SOCKET` and `osdefs.INVALID_HANDLE_VALUE` on every
  ## platform, so a minted id can never equal a sentinel value a
  ## teardown path `doAssert`s against directly.
  result = state.nextFdValue
  if result == -1:
    inc result
  state.nextFdValue = result + 1
  state.endpoints.incl(result)

proc ownsSimFd*(state: SimEngineState, value: int): bool =
  ## The fd provenance guard's membership test: `true` only for ids this
  ## run minted. Deliberately not a numeric-range partition - minted ids
  ## share the OS fd domain with kernel-assigned fds and cannot be
  ## soundly separated by value.
  value in state.endpoints

proc isSimBarrier*(code: OSErrorCode): bool {.inline.} =
  code == SimBarrierCode

proc raiseIfSimBarrier*(code: OSErrorCode) {.raises: [SimBarrierError].} =
  if isSimBarrier(code):
    raise newException(SimBarrierError,
      "simulation barrier: a provenance-guarded call reached a real " &
      "OS resource under -d:chronosSimulation")

proc simDecideTimeAdvance*(state: SimEngineState, armed: seq[Moment],
                            curTime: Moment): Moment =
  ## The virtual clock's sole write point (3.4): asks `state`'s oracle
  ## to pick an advance among `armed` (sorted earliest first by the
  ## caller) and writes the sim clock counter to its answer.
  ##
  ## An oracle failure or a `decideTime` answer outside the engine's
  ## validation rule (`>= armed[0]` and `>= curTime`) is a structured
  ## simulation-protocol violation. There is no per-seed failure
  ## channel yet - `simulate`/`sweepSeeds` land in S8 - so for now this
  ## reports the same way `poll()`'s own `raiseOsDefect` does for an
  ## unrecoverable real-mode condition: a Defect carrying the message,
  ## not a silent or backward clock write.
  doAssert armed.len > 0,
    "simDecideTimeAdvance(): requires at least one armed deadline"
  let decision = state.oracle.decideTimeImpl(TimeAdvancePoint(armed: armed))
  if decision.isErr:
    raiseAssert "simulation oracle error: " & decision.error.msg
  let advanceTo = decision.get().advanceTo
  if advanceTo < armed[0] or advanceTo < curTime:
    raiseAssert "simulation clock violation: decideTime returned " &
      $advanceTo & ", earlier than the earliest armed deadline or the " &
      "current virtual clock"
  setSimClockNanoseconds(advanceTo.epochNanoSeconds)
  advanceTo
