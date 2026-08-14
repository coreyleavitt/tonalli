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
## reserved barrier error code, `SimBarrierError`, the discrete-event
## virtual clock's `decideTime` choice point, and the sim event set's
## `decideBatch` choice point (readiness/arrival delivery order, oracle
## interface, and the registration-routing bookkeeping that lets
## sim-minted fds carry armed reader/writer interest with no selector).
##
## Imported by `chronos/internal/asyncengine.nim` under
## `-d:chronosSimulation`; this module never imports it back, so a
## simulated `Dispatcher`'s construction fork, provenance-guarded touch
## sites, and poll-loop extension points are the only consumers of the
## types below.

{.push raises: [], gcsafe.}

import std/[algorithm, sets, tables]
import results
import ../oserrno
import ../timer
import ../futures
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

  SimEventId* = distinct uint64
    ## Monotonic per-run counter (RFC 0003 3.3.1): every `SimEvent`, a
    ## `Readiness` completion or an `Arrival` batch alike, gets its id
    ## from one counter owned by `SimEngineState`, so ids sort into a
    ## single total order regardless of which choice point produced
    ## them.

  SimEndpointId* = distinct uint32
    ## The id of a `SimEvent`'s source. At this slice, `Readiness`
    ## events derive it directly from the sim-minted fd their interest
    ## was armed against - itself already a `mintSimFd` counter value,
    ## so this stays pointer-free per 3.3.1 without a second minting
    ## counter. A real transport endpoint identity (`SimNet`, S11a) may
    ## supersede this mapping without changing the type.

  SimEventKind* {.pure.} = enum
    Readiness  ## a simulated endpoint has a completion for a registered callback
    Arrival    ## a scripted cross-thread arrival batch lands (S13 stub here)

  SimEvent* = object
    id*: SimEventId
    kind*: SimEventKind
    source*: SimEndpointId

  SelectBatchPoint* = object
    deliverable*: seq[SimEvent]
      ## Everything legal to deliver this iteration, always sorted by
      ## `SimEventId` (3.3's stable-alternative-order house rule).

  BatchDecision* = object
    order*: seq[SimEventId]
      ## Ids from `deliverable`, in delivery order; empty defers
      ## delivery, legal only with a fallback (armed timers or queued
      ## work - 3.5's deferral protocol).

  SimOracleError* = object
    ## A value, not a `ref` exception, matching every in-tree `Result`
    ## error type (3.3's "Failure channel" note). Shared by every
    ## choice point.
    msg*: string

  SimOracle* = object
    ## Fields private outside the sim modules; `newSimOracle` is the
    ## sole constructor (3.3's "Construction discipline"). `decideIo`
    ## is S10's job, added the same additive-safe way.
    decideBatchImpl: proc(cp: SelectBatchPoint):
      Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].}
    decideTimeImpl: proc(cp: TimeAdvancePoint):
      Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].}

  SimReadyDirection* {.pure.} = enum
    Read
    Write

  SimInterest = object
    ## Registration routing's bookkeeping for one sim-minted fd (RFC
    ## 0003 3.2 point 2): the armed reader/writer callbacks, recorded
    ## and cleared by `addReader2`/`addWriter2`/`removeReader2`/
    ## `removeWriter2`'s sim branch instead of touching a nil selector.
    reader: InternalAsyncCallback
    writer: InternalAsyncCallback

  SimReadyEvent = object
    event: SimEvent
    callback: InternalAsyncCallback

  SimEngineState* = ref object
    ## The sim-mode run state carried on a simulated `Dispatcher`: the
    ## fd provenance table, populated at mint time and consulted by
    ## every registration/teardown touch site before it acts on a fd,
    ## the counter that mints it, the oracle driving the virtual
    ## clock's `decideTime` and the sim event set's `decideBatch`
    ## choice points, the registration-routing interest table, and the
    ## pending readiness/arrival events awaiting delivery.
    endpoints: HashSet[int]
    nextFdValue: int
    oracle: SimOracle
    interest: Table[int, SimInterest]
    nextEventId: uint64
    readyQueue: seq[SimReadyEvent]
    arrivalQueue: seq[SimEvent]

const
  SimBarrierCode* = OSErrorCode(1_397_835_586'i32)
    ## Reserved `OSErrorCode`, outside every platform's errno range
    ## ("SIMB" packed as ASCII bytes). A provenance-guarded touch site
    ## under simulation returns `err(SimBarrierCode)` through its
    ## unchanged `Result` signature instead of touching a real fd or a
    ## nil selector.

proc `==`*(a, b: SimEventId): bool {.borrow.}
proc `<`*(a, b: SimEventId): bool {.borrow.}
proc `$`*(id: SimEventId): string =
  "e" & $uint64(id)

proc `==`*(a, b: SimEndpointId): bool {.borrow.}
proc `$`*(id: SimEndpointId): string =
  "p" & $uint32(id)

proc newSimOracle*(
    decideBatch: proc(cp: SelectBatchPoint):
      Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].},
    decideTime: proc(cp: TimeAdvancePoint):
      Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].}): SimOracle =
  SimOracle(decideBatchImpl: decideBatch, decideTimeImpl: decideTime)

proc defaultDecideBatch(cp: SelectBatchPoint):
    Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
  ## The default batch rule: deliver everything deliverable, in the
  ## stable sorted order `cp.deliverable` already carries - the sim
  ## analogue of a real `select()` batch, where nothing is withheld
  ## absent a reason to explore otherwise.
  var order = newSeq[SimEventId](cp.deliverable.len)
  for i, ev in cp.deliverable:
    order[i] = ev.id
  ok(BatchDecision(order: order))

proc defaultDecideTime(cp: TimeAdvancePoint):
    Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
  ok(TimeDecision(advanceTo: cp.armed[0]))

proc defaultSimOracle*(): SimOracle =
  ## The default choice-point rules every scripted stub oracle falls
  ## back to unless it overrides a `decide*` closure itself: `decideTime`
  ## jumps straight to the earliest armed deadline (S3), `decideBatch`
  ## delivers everything deliverable in sorted order (S4).
  newSimOracle(defaultDecideBatch, defaultDecideTime)

proc newSimEngineState*(startValue: int = 0,
                         oracle: SimOracle = defaultSimOracle()): SimEngineState =
  SimEngineState(endpoints: initHashSet[int](), nextFdValue: startValue,
                  oracle: oracle, interest: initTable[int, SimInterest]())

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

proc simSetReaderInterest*(state: SimEngineState, fd: int,
                            cb: InternalAsyncCallback) =
  ## Registration routing (RFC 0003 3.2 point 2): records the callback
  ## `addReader2`'s sim branch would otherwise have handed to a real
  ## selector. Overwriting an already-armed reader is legal re-arming,
  ## the same as the real selector path.
  var entry = state.interest.getOrDefault(fd)
  entry.reader = cb
  state.interest[fd] = entry

proc simSetWriterInterest*(state: SimEngineState, fd: int,
                            cb: InternalAsyncCallback) =
  var entry = state.interest.getOrDefault(fd)
  entry.writer = cb
  state.interest[fd] = entry

proc simClearReaderInterest*(state: SimEngineState, fd: int) =
  var entry = state.interest.getOrDefault(fd)
  entry.reader = InternalAsyncCallback()
  state.interest[fd] = entry

proc simClearWriterInterest*(state: SimEngineState, fd: int) =
  var entry = state.interest.getOrDefault(fd)
  entry.writer = InternalAsyncCallback()
  state.interest[fd] = entry

proc simMarkReady*(state: SimEngineState, fd: int,
                    direction: SimReadyDirection): SimEventId =
  ## Enqueues a `Readiness` event for `fd`'s currently-armed `direction`
  ## interest, minting a fresh `SimEventId` from the shared per-run
  ## event counter. `S10`/`S11a`'s transport seam is the production
  ## source of `Readiness` events; until then, this is how a test
  ## scripts one directly.
  let entry = state.interest.getOrDefault(fd)
  let cb = if direction == SimReadyDirection.Read: entry.reader else: entry.writer
  doAssert not isNil(cb.function),
    "simMarkReady(): fd " & $fd & " has no armed " & $direction & " interest"
  let id = SimEventId(state.nextEventId)
  inc state.nextEventId
  state.readyQueue.add SimReadyEvent(
    event: SimEvent(id: id, kind: SimEventKind.Readiness,
                     source: SimEndpointId(uint32(fd))),
    callback: cb)
  id

proc simScheduleArrival*(state: SimEngineState): SimEventId =
  ## Schedules a stub `Arrival` event (RFC 0003 3.5/3.6): delivery
  ## drains through `processThreadCallbacks` unconditionally, with no
  ## actor identity or payload. `simProducer` (S13) supersedes this;
  ## it exists now purely so `decideBatch`'s delivery loop has both
  ## `SimEventKind` branches to route additively.
  let id = SimEventId(state.nextEventId)
  inc state.nextEventId
  state.arrivalQueue.add SimEvent(id: id, kind: SimEventKind.Arrival,
                                   source: SimEndpointId(0))
  id

proc simDeliverableEvents*(state: SimEngineState): seq[SimEvent] =
  ## `deliverable`, sorted by id (3.3's stable-alternative-order house
  ## rule: never a `Table`/`HashSet` iteration order). Built fresh on
  ## every call from whatever readiness/arrival events are still
  ## pending; never mutates `state`.
  result = newSeq[SimEvent](state.readyQueue.len + state.arrivalQueue.len)
  var i = 0
  for r in state.readyQueue:
    result[i] = r.event
    inc i
  for a in state.arrivalQueue:
    result[i] = a
    inc i
  result.sort(proc(x, y: SimEvent): int = cmp(uint64(x.id), uint64(y.id)))

proc simDecideBatch*(state: SimEngineState,
                      deliverable: seq[SimEvent]): BatchDecision =
  ## Asks the oracle to choose a delivery order among `deliverable`
  ## (RFC 0003 3.3/3.5). Validates every returned id is a member of
  ## `deliverable`, appearing at most once - an oracle answer naming an
  ## unknown or duplicate id is a structured simulation-protocol
  ## violation, the same `raiseAssert` discipline `simDecideTimeAdvance`
  ## already uses (no per-seed failure channel exists yet; S8 adds one).
  let decision = state.oracle.decideBatchImpl(
    SelectBatchPoint(deliverable: deliverable))
  if decision.isErr:
    raiseAssert "simulation oracle error: " & decision.error.msg
  result = decision.get()
  var seen = initHashSet[uint64]()
  for id in result.order:
    var found = false
    for ev in deliverable:
      if ev.id == id:
        found = true
        break
    if not found:
      raiseAssert "simulation batch violation: decideBatch named an id " &
        "not in deliverable: " & $id
    if uint64(id) in seen:
      raiseAssert "simulation batch violation: decideBatch named id " &
        $id & " more than once"
    seen.incl(uint64(id))

proc simTakeDelivery*(state: SimEngineState, id: SimEventId):
    tuple[kind: SimEventKind, callback: InternalAsyncCallback] =
  ## Pops the delivery payload for `id`, already validated against the
  ## pending event set by `simDecideBatch`: the armed callback for a
  ## `Readiness` event, or a bare `Arrival` marker (S13 gives it a real
  ## payload; asyncengine.nim's poll() drains it through the unmodified
  ## `processThreadCallbacks` path per RFC 0003 3.5).
  for idx in 0 ..< state.readyQueue.len:
    if state.readyQueue[idx].event.id == id:
      result = (SimEventKind.Readiness, state.readyQueue[idx].callback)
      state.readyQueue.delete(idx)
      return
  for idx in 0 ..< state.arrivalQueue.len:
    if state.arrivalQueue[idx].id == id:
      result = (SimEventKind.Arrival, InternalAsyncCallback())
      state.arrivalQueue.delete(idx)
      return
  raiseAssert "simTakeDelivery(): unknown id " & $id &
    " - validated ids must exist in the pending event set"
