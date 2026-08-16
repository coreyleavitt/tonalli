#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Private mechanism backing the deterministic simulation substrate's
## dispatcher fork: the fd provenance table and its minting counter,
## `SimBarrierError` and `raiseSimBarrier` (a provenance-guarded touch
## site's typed, catchable failure - raised directly at the point of
## detection, never encoded through a reserved `OSErrorCode`), the
## discrete-event virtual clock's `decideTime` choice point, the sim
## event set's `decideBatch` choice point (readiness/arrival delivery
## order, oracle interface, and the registration-routing bookkeeping
## that lets sim-minted fds carry armed reader/writer interest with no
## selector), and the I/O outcome's `decideIo` choice point (RFC 0003
## 3.3's D2 triple, completed at S6; no live producer wires it before
## the transport seam at S10). Also `RandomOracle`, the seeded stock
## oracle scripted stub oracles are an alternative to, and
## `SimEngineError`/`SimFailureKind`, the typed, by-type-classified
## failure the engine's own protocol/livelock checks raise directly
## (retiring the `AssertionDefect`-plus-message-prefix trampoline
## `chronos/simulation.nim`'s `simulate()` used to convert those checks
## through).
##
## Imports and re-exports `chronos/internal/simtrace.nim` for the
## entity-id types every choice point and decision carries; this module
## never imports `chronos/internal/asyncengine.nim` back, so a simulated
## `Dispatcher`'s construction fork, provenance-guarded touch sites, and
## poll-loop extension points are the only consumers of the types below.

{.push raises: [], gcsafe.}

import std/[algorithm, deques, sets, strutils, tables]
import results
import ../oserrno
import ../timer
import ../futures
import ./simclock
import ./simtrace
import ./simledger

export simtrace, simledger

type
  SimBarrierError* = object of CatchableError
    ## Raised where a call site's signature can carry a typed error: a
    ## simulated dispatcher's fd provenance guard was crossed by a real
    ## fd, or a cross-thread entry point incompatible with simulation
    ## (`wake()`, `handle()`) was reached. Deliberately not a subtype of
    ## `AsyncError`, so an existing `except AsyncError` handler cannot
    ## silently swallow a hermeticity violation. Raised directly, by
    ## `raiseSimBarrier` below, at the point of detection - never
    ## encoded through a reserved `OSErrorCode` threaded through an
    ## otherwise-unchanged `Result` return.

  SimFailureKind* {.pure.} = enum
    ## What made a `simulate()` run fail (RFC 0003 3.8). `BodyError` and
    ## `BarrierHit` are both classified by `chronos/simulation.nim`'s
    ## `runSimulation` itself, never raised from in here: `BodyError`
    ## names the async body's own exception, and `BarrierHit` names a
    ## propagated or Defect-enveloped `SimBarrierError` - a hermeticity
    ## violation (an un-barriered producer touching the sim dispatcher),
    ## distinct from an ordinary body bug even though both surface
    ## through the body. The rest name every failure `SimEngineError`
    ## carries directly from its point of detection in this module or
    ## in `asyncengine.nim`'s sim poll loop - `kind` classifies which,
    ## by a type-safe field, never by parsing `msg`.
    BodyError
    BarrierHit
    Deadlock
    OracleDeferral
    ProtocolViolation
    DecisionBudgetExhausted
    TimeBudgetExhausted

  SimEngineError* = object of CatchableError
    ## Raised directly, at the point of detection, for every internal
    ## sim run failure the engine or the sim poll loop can detect on
    ## its own (RFC 0003 3.5/3.8): an oracle error, an out-of-range
    ## oracle answer, a decision- or virtual-time-budget exhaustion, a
    ## deadlock (no runnable work), or an oracle deferring all
    ## deliverable work with no fallback. `kind` classifies which;
    ## `chronos/simulation.nim`'s `runSimulation` is the sole boundary
    ## that catches this (by type, via a plain `except SimEngineError`)
    ## and converts it into the public, per-seed `SimulationError` -
    ## retiring the `AssertionDefect`-plus-message-prefix trampoline
    ## this used to flow through, which was the only shape available
    ## while `poll()`'s `raises: []` surface and
    ## `chronos/internal/asyncfutures.nim` were untouchable.
    kind*: SimFailureKind

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

  SimIoOp* {.pure.} = enum
    ## `IoOutcomePoint.op`'s membership is finalized in S10 (stream seam)
    ## and S12a (datagram seam); S6 needs a concrete type to exercise
    ## `decideIo` ahead of either seam existing, so it takes the two
    ## names those extraction sites already use.
    Read
    Write

  SimFault* {.pure.} = enum
    ## `IoOutcomePoint.faults`'s full membership, finalized across S11b/
    ## S12b's fault-injection RED phases (RFC 0003 3.3's slice table).
    ## `Reset` is a recv-side choice (S11b/S12b): the local read fails,
    ## the same real `OSErrorCode` a real platform's ECONNRESET-after-
    ## ICMP-unreachable would surface (`simFaultToError`). `Drop`/
    ## `Duplicate`/`Reorder` (S12b, datagram-only so far) are write-side
    ## choices instead: none of them fail the local send (real UDP never
    ## fails a send over packet loss) - `simDatagramIo`'s write branch
    ## intercepts each by name before it would otherwise reach
    ## `simFaultToError`, which has no translation for them.
    Reset
    Drop
    Duplicate
    Reorder

  IoOutcomePoint* = object
    ## One I/O completion's decision point (RFC 0003 3.3): asked while a
    ## callback delivered by an earlier `decideBatch` decision executes
    ## its transport operation. No live producer wires this before S10;
    ## S6 exercises it with hand-built values.
    trigger*: SimEventId
    endpoint*: SimEndpointId
    op*: SimIoOp
    maxBytes*: int
    faults*: set[SimFault]

  SimIoOutcome* {.pure.} = enum
    Ok
    Fault

  IoDecision* = object
    case outcome*: SimIoOutcome
    of SimIoOutcome.Ok:
      bytes*: int
    of SimIoOutcome.Fault:
      fault*: SimFault

  SimOracleError* = object
    ## A value, not a `ref` exception, matching every in-tree `Result`
    ## error type (3.3's "Failure channel" note). Shared by every
    ## choice point. `expected`/`actual` carry a replay digest mismatch
    ## (RFC 0003 3.3, 3.7's `ReplayOracle`); every other failure leaves
    ## them at their zero value.
    msg*: string
    expected*, actual*: SimDigest

  SimOracle* = object
    ## Fields private outside the sim modules; `newSimOracle` is the
    ## sole constructor (3.3's "Construction discipline").
    decideBatchImpl: proc(cp: SelectBatchPoint):
      Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].}
    decideIoImpl: proc(cp: IoOutcomePoint):
      Result[IoDecision, SimOracleError] {.gcsafe, raises: [].}
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

  SimDatagramMessage = object
    ## One queued whole datagram (RFC 0003 6, S12b): unlike a stream
    ## endpoint's `Deque[byte]`, a datagram endpoint's queue holds
    ## discrete messages - a read always consumes exactly one, in full
    ## or truncated, never a byte-sliced view spanning two of them, the
    ## same convention a real `recvfrom()` enforces. `fromAddr` is the
    ## sender's own address at send time, in raw OS-level bytes (never a
    ## `TransportAddress` - the engine layer stays transport-agnostic,
    ## the same layering `chronos/simulation.nim`'s `SimNet` listener
    ## table already keeps; `chronos/transports/datagram.nim` is the one
    ## place that converts to/from `Sockaddr_storage` on both ends of
    ## this seam).
    data: seq[byte]
    fromAddr: seq[byte]

  SimDatagramEndpoint = object
    ## One side of a minted sim datagram pair (RFC 0003 6, S12b):
    ## `peerFd` routes a write to the other side's `inbound` queue, the
    ## same fixed-pair scope `SimStreamEndpoint.peerFd` already accepts
    ## for streams - a real UDP socket can `sendTo()` any address, but a
    ## sim pair is wired at mint time, not per send.
    id: SimEndpointId
    peerFd: int
    localAddr: seq[byte]
    inbound: Deque[SimDatagramMessage]

  SimStreamEndpoint = object
    ## One side of an in-memory stream endpoint pair (RFC 0003 3.2's
    ## sim-native connection setup, slice S11a): `id` is this
    ## endpoint's own identity, minted from its own counter rather
    ## than cast from the fd (S4's provisional shortcut, settled
    ## here); `peerFd` routes a write to the other side's `inbound`
    ## queue; `peerClosed` is set by the peer's half-close
    ## (`simStreamHalfClose`) and, once `inbound` drains, turns the
    ## next read into EOF - the same `res == 0` convention a real
    ## socket read uses.
    id: SimEndpointId
    peerFd: int
    inbound: Deque[byte]
    peerClosed: bool

  SimEngineState* = ref object
    ## The sim-mode run state carried on a simulated `Dispatcher`: the
    ## fd provenance table, populated at mint time and consulted by
    ## every registration/teardown touch site before it acts on a fd,
    ## the counter that mints it, the oracle driving the virtual
    ## clock's `decideTime` and the sim event set's `decideBatch`
    ## choice points, the registration-routing interest table, the
    ## pending readiness/arrival events awaiting delivery, and the
    ## harness's (RFC 0003 3.8) decision/time budgets and live trace
    ## writer.
    endpoints: HashSet[int]
    nextFdValue: int
    oracle: SimOracle
    interest: Table[int, SimInterest]
    nextEventId: uint64
    readyQueue: seq[SimReadyEvent]
    arrivalQueue: seq[SimEvent]
    decisionBudget: int
    decisionCount: int
    seed: uint64
    hasTimeBudget: bool
    timeBudgetCutoffNanoseconds: int64
    traceWriter: ptr SimTraceWriter
    streamEndpoints: Table[int, SimStreamEndpoint]
    datagramEndpoints: Table[int, SimDatagramEndpoint]
    nextEndpointIdValue: uint32
    ledger: SimLedgerState
      ## `nil` unless the caller opted into ledger checking (RFC 0003
      ## 3.9, slice S14): `chronos/simulation.nim`'s
      ## `simulateWith(seed, simOptions(ledger = true))` is the sole
      ## caller that constructs one, so the existing
      ## `simulate()`/`sweepSeeds` entry points and every pre-S14 test
      ## are unaffected. `simLedgerState()` below is the sole accessor -
      ## every field on this object stays private to this module, the
      ## same discipline the rest of `SimEngineState` already follows.

proc raiseSimBarrier*(site: string) {.noreturn, raises: [SimBarrierError].} =
  ## Raised directly by a provenance-guarded touch site (RFC 0003 3.2)
  ## reached by a real fd or resource, or an API that inherently
  ## touches a real OS resource, under simulation - retires the
  ## reserved-`OSErrorCode` sentinel (`SimBarrierCode`/`isSimBarrier`/
  ## `raiseIfSimBarrier`) this used to flow through as a magic value
  ## threaded through the touch site's otherwise-unchanged real-mode
  ## `Result` signature. `site` names the specific touch site.
  raise newException(SimBarrierError,
    "simulation barrier: " & site & " reached a real OS resource " &
    "under -d:chronosSimulation")

proc raiseSimEngineError*(kind: SimFailureKind, msg: string)
                          {.noreturn, raises: [SimEngineError].} =
  ## Raised directly by every internal sim-engine/poll-loop check this
  ## module and `asyncengine.nim`'s sim poll loop make (RFC 0003
  ## 3.5/3.8) - see `SimEngineError`.
  let exc = newException(SimEngineError, msg)
  exc.kind = kind
  raise exc

proc newSimOracle*(
    decideBatch: proc(cp: SelectBatchPoint):
      Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].},
    decideIo: proc(cp: IoOutcomePoint):
      Result[IoDecision, SimOracleError] {.gcsafe, raises: [].},
    decideTime: proc(cp: TimeAdvancePoint):
      Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].}): SimOracle =
  SimOracle(decideBatchImpl: decideBatch, decideIoImpl: decideIo,
            decideTimeImpl: decideTime)

proc defaultDecideBatch*(cp: SelectBatchPoint):
    Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
  ## The default batch rule: deliver everything deliverable, in the
  ## stable sorted order `cp.deliverable` already carries - the sim
  ## analogue of a real `select()` batch, where nothing is withheld
  ## absent a reason to explore otherwise. Exported so a test or a
  ## scripted oracle fixing two of the three choice points can reuse
  ## it for the third instead of reimplementing it.
  var order = newSeq[SimEventId](cp.deliverable.len)
  for i, ev in cp.deliverable:
    order[i] = ev.id
  ok(BatchDecision(order: order))

proc defaultDecideIo*(cp: IoOutcomePoint):
    Result[IoDecision, SimOracleError] {.gcsafe, raises: [].} =
  ## The default I/O rule: complete fully at the requested size with no
  ## fault, the sim analogue of a real read/write that always succeeds -
  ## the same "nothing withheld absent a reason to explore otherwise"
  ## default `defaultDecideBatch` uses.
  ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: cp.maxBytes))

proc defaultDecideTime*(cp: TimeAdvancePoint):
    Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
  ## The default time rule: advance to the earliest armed deadline.
  ## Exported for the same reason as `defaultDecideBatch`.
  ok(TimeDecision(advanceTo: cp.armed[0]))

proc defaultSimOracle*(): SimOracle =
  ## The default choice-point rules every scripted stub oracle falls
  ## back to unless it overrides a `decide*` closure itself: `decideTime`
  ## jumps straight to the earliest armed deadline (S3), `decideBatch`
  ## delivers everything deliverable in sorted order (S4), `decideIo`
  ## completes every operation fully with no fault (S6).
  newSimOracle(defaultDecideBatch, defaultDecideIo, defaultDecideTime)

type
  SplitMix64 = object
    ## A self-contained generator, not `std/random`'s global state (RFC
    ## 0003 3.3's "Statefulness" note: an oracle's mutable state lives in
    ## its closure captures). Algorithm: Vigna/Steele's splitmix64.
    state: uint64

proc initSplitMix64(seed: uint64): SplitMix64 =
  SplitMix64(state: seed)

proc next(rng: var SplitMix64): uint64 =
  rng.state = rng.state + 0x9E3779B97F4A7C15'u64
  var z = rng.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc shuffled(rng: var SplitMix64, ids: seq[SimEventId]): seq[SimEventId] =
  ## Fisher-Yates over `ids`, draws from `rng`.
  result = ids
  for i in countdown(result.high, 1):
    let j = int(rng.next() mod uint64(i + 1))
    swap(result[i], result[j])

proc RandomOracle*(seed: uint64): SimOracle =
  ## A seeded oracle (RFC 0003 3.3, 3.7): the same seed produces the
  ## same decisions on every run. `decideBatch` shuffles `deliverable`
  ## into a random legal delivery order, the sim analogue of N2's
  ## OS-chosen cross-fd batch order; `decideIo` draws a uniform size in
  ## `1..maxBytes` (S11b), the sim analogue of a real read/write that
  ## may complete short - full completion is one of the possible draws,
  ## not a separate case; `decideTime` uses the same
  ## earliest-armed-deadline rule as `defaultSimOracle` - randomizing
  ## among armed deadlines is exploration-oracle territory (issue #10),
  ## out of scope here. Faults are never synthesized here even though
  ## the `SimFault` menu is no longer empty as of S12b: fault injection
  ## stays scripted-oracle territory (`testsimstream.nim`/
  ## `testsimdatagram.nim`'s own scripted `decideIo` overrides), the
  ## same deliberate split `decideBatch`'s exploration-oracle carve-out
  ## above already draws. A live datagram endpoint's write under this
  ## oracle can still draw a partial byte count the same as a stream
  ## write does - datagram sends are atomic on a real platform, so this
  ## is a known, recorded gap rather than a modeled behavior; no test in
  ## this slice exercises a datagram endpoint under `RandomOracle`.
  var rng = initSplitMix64(seed)
  proc decideBatch(cp: SelectBatchPoint):
      Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
    var ids = newSeq[SimEventId](cp.deliverable.len)
    for i, ev in cp.deliverable:
      ids[i] = ev.id
    ok(BatchDecision(order: shuffled(rng, ids)))
  proc decideIo(cp: IoOutcomePoint):
      Result[IoDecision, SimOracleError] {.gcsafe, raises: [].} =
    let bytes =
      if cp.maxBytes <= 1: cp.maxBytes
      else: 1 + int(rng.next() mod uint64(cp.maxBytes))
    ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: bytes))
  newSimOracle(decideBatch, decideIo, defaultDecideTime)

proc ReplayOracle*(records: seq[SimTraceRecord]): SimOracle =
  ## As `ReplayOracle(path: string)`, from a trace already read and
  ## parsed by the caller - `simulateReplay` uses this directly so a
  ## trace read once for seed attribution is never re-parsed for the
  ## oracle. At each choice point, verifies the live digest against the
  ## next recorded one - via the same `digestOf` the writer uses, so
  ## "digest mismatch" cannot mean two different things - and returns
  ## the recorded decision. A live digest diverging from the recording
  ## is reported through the `Result` error channel as a structured
  ## `SimOracleError` carrying the expected and actual digest, never a
  ## silent wrong decision and never a Defect raised from inside the
  ## oracle itself.
  var cursor = 0

  proc nextRecord(kind: SimTraceRecordKind, liveDigest: SimDigest):
      Result[SimTraceRecord, SimOracleError] {.gcsafe, raises: [].} =
    if cursor >= records.len:
      return err(SimOracleError(msg: "replay exhausted: no recorded " &
        "decision at index " & $cursor))
    let rec = records[cursor]
    if rec.kind != kind:
      return err(SimOracleError(msg: "replay divergence at index " &
        $cursor & ": recorded a " & $rec.kind & " decision, live run " &
        "asked for " & $kind))
    if rec.digest != liveDigest:
      return err(SimOracleError(
        msg: "replay divergence at index " & $cursor & " (" & $kind &
          "): expected digest " & $rec.digest & ", live digest " &
          $liveDigest,
        expected: rec.digest, actual: liveDigest))
    inc cursor
    ok(rec)

  proc decideBatch(cp: SelectBatchPoint):
      Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
    var ids = newSeq[SimEventId](cp.deliverable.len)
    for i, ev in cp.deliverable:
      ids[i] = ev.id
    let recorded = nextRecord(SimTraceRecordKind.Batch, digestOf(ids))
    if recorded.isErr:
      return err(recorded.error)
    ok(BatchDecision(order: recorded.get().order))

  proc decideIo(cp: IoOutcomePoint):
      Result[IoDecision, SimOracleError] {.gcsafe, raises: [].} =
    var faultNames = newSeq[string]()
    for f in cp.faults:
      faultNames.add toLowerAscii($f)
    let liveDigest = digestOf(cp.trigger, cp.endpoint, toLowerAscii($cp.op),
                               cp.maxBytes, faultNames)
    let recorded = nextRecord(SimTraceRecordKind.Io, liveDigest)
    if recorded.isErr:
      return err(recorded.error)
    let rec = recorded.get()
    if rec.outcome == "ok":
      return ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: rec.bytes))
    case rec.fault
    of "reset":
      ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Reset))
    of "drop":
      ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Drop))
    of "duplicate":
      ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Duplicate))
    of "reorder":
      ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Reorder))
    else:
      err(SimOracleError(msg: "replay: unrecognized fault name in " &
        "trace: " & rec.fault))

  proc decideTime(cp: TimeAdvancePoint):
      Result[TimeDecision, SimOracleError] {.gcsafe, raises: [].} =
    var deadlines = newSeq[int64](cp.armed.len)
    for i, m in cp.armed:
      deadlines[i] = m.epochNanoSeconds
    let recorded = nextRecord(SimTraceRecordKind.Time, digestOf(deadlines))
    if recorded.isErr:
      return err(recorded.error)
    ok(TimeDecision(
      advanceTo: Moment.init(recorded.get().advanceToNanoseconds, Nanosecond)))

  newSimOracle(decideBatch, decideIo, decideTime)

proc ReplayOracle*(path: string): SimOracle
                   {.raises: [IOError, SimTraceReadError].} =
  ## Constructed from a recorded trace (RFC 0003 3.3, 3.7). A version-
  ## mismatched trace is refused here, at construction (3.7's version
  ## gate, enforced by `readSimTrace`). See the `seq[SimTraceRecord]`
  ## overload above for the oracle itself; a caller that also needs the
  ## trace's header (`simulateReplay`'s seed attribution) should call
  ## `readSimTrace` once and pass `.records` there directly instead of
  ## going through this path-only convenience wrapper, which reads the
  ## file itself.
  ReplayOracle(readSimTrace(path).records)

proc newSimEngineState*(startValue: int = 0,
                         oracle: SimOracle = defaultSimOracle(),
                         decisionBudget: int = 0,
                         seed: uint64 = 0,
                         hasTimeBudget: bool = false,
                         timeBudgetCutoffNanoseconds: int64 = 0,
                         enableLedger: bool = false): SimEngineState =
  ## `decisionBudget`/`hasTimeBudget`/`timeBudgetCutoffNanoseconds` are
  ## the harness's livelock bounds (RFC 0003 3.8); zero/`false` (the
  ## default) means unlimited, which is what every pre-S8 caller of
  ## this constructor still gets. `seed` is carried only for budget-
  ## exhaustion messages and the trace writer's records. `enableLedger`
  ## (default `false`, so every existing caller is unaffected) turns on
  ## the D8 ghost-ledger laws (RFC 0003 3.9, slice S14).
  SimEngineState(endpoints: initHashSet[int](), nextFdValue: startValue,
                  oracle: oracle, interest: initTable[int, SimInterest](),
                  decisionBudget: decisionBudget, seed: seed,
                  hasTimeBudget: hasTimeBudget,
                  timeBudgetCutoffNanoseconds: timeBudgetCutoffNanoseconds,
                  streamEndpoints: initTable[int, SimStreamEndpoint](),
                  datagramEndpoints: initTable[int, SimDatagramEndpoint](),
                  ledger: (if enableLedger: newSimLedgerState() else: nil))

proc simLedgerState*(state: SimEngineState): SimLedgerState {.inline.} =
  ## `nil` unless the run opted into ledger checking - see the `ledger`
  ## field's docstring above.
  state.ledger

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

proc mintSimEndpointId(state: SimEngineState): SimEndpointId =
  ## Real per-endpoint identity (RFC 0003 3.3.1's per-kind monotonic
  ## counter), independent of the fd-domain counter `mintSimFd` owns:
  ## an endpoint's identity in a choice point, digest, or trace record
  ## must not be a cast of whatever integer the fd-provenance table
  ## happens to have minted for it (S4's provisional shortcut).
  result = SimEndpointId(state.nextEndpointIdValue)
  inc state.nextEndpointIdValue

proc attachTraceWriter*(state: SimEngineState, writer: ptr SimTraceWriter) =
  ## Wires a live decision-log writer into `state` (RFC 0003 3.7/3.8):
  ## `chronos/simulation.nim`'s `simulate()` is the sole caller. `nil`
  ## detaches, which `simulate()` does at teardown so a closed file is
  ## never touched again by a later call reusing this engine state.
  state.traceWriter = writer

proc noteDecision(state: SimEngineState) {.raises: [SimEngineError].} =
  ## Counts one oracle `decide*` call against the run's decision budget
  ## (RFC 0003 3.8): the same mechanism bounds a runaway poll loop
  ## (`decideBatch`/`decideTime`, once per iteration) and a retry spin
  ## inside one callback (`decideIo`, once per sub-step). Exhaustion is
  ## a livelock, raised directly as a typed `SimEngineError` -
  ## `simulate()` (chronos/simulation.nim) is the boundary that catches
  ## it by type and converts it into a catchable, structured outcome.
  inc state.decisionCount
  if state.decisionBudget > 0 and state.decisionCount > state.decisionBudget:
    raiseSimEngineError(SimFailureKind.DecisionBudgetExhausted,
      "livelock: decision budget exhausted at decision " &
      $state.decisionCount & ", seed " & $state.seed)

proc simDecideTimeAdvance*(state: SimEngineState, armed: seq[Moment],
                            curTime: Moment): Moment
                           {.raises: [SimEngineError].} =
  ## The virtual clock's sole write point (3.4): asks `state`'s oracle
  ## to pick an advance among `armed` (sorted earliest first by the
  ## caller) and writes the sim clock counter to its answer.
  ##
  ## An oracle failure or a `decideTime` answer outside the engine's
  ## validation rule (`>= armed[0]` and `>= curTime`) is a structured
  ## simulation-protocol violation, raised directly as a typed
  ## `SimEngineError` - never a silent or backward clock write.
  ## `chronos/simulation.nim`'s `runSimulation` is the boundary that
  ## catches it by type and converts it into a catchable, per-seed
  ## `SimulationError`.
  doAssert armed.len > 0,
    "simDecideTimeAdvance(): requires at least one armed deadline"
  state.noteDecision()
  let decision = state.oracle.decideTimeImpl(TimeAdvancePoint(armed: armed))
  if decision.isErr:
    raiseSimEngineError(SimFailureKind.ProtocolViolation,
      "simulation oracle error: " & decision.error.msg)
  let advanceTo = decision.get().advanceTo
  if advanceTo < armed[0] or advanceTo < curTime:
    raiseSimEngineError(SimFailureKind.ProtocolViolation,
      "simulation clock violation: decideTime returned " &
      $advanceTo & ", earlier than the earliest armed deadline or the " &
      "current virtual clock")
  if state.hasTimeBudget and
     advanceTo.epochNanoSeconds > state.timeBudgetCutoffNanoseconds:
    raiseSimEngineError(SimFailureKind.TimeBudgetExhausted,
      "livelock: virtual-time budget exhausted at decision " &
      $state.decisionCount & ", seed " & $state.seed & ", virtual time " &
      $advanceTo.epochNanoSeconds & "ns")
  setSimClockNanoseconds(advanceTo.epochNanoSeconds)
  if not state.traceWriter.isNil:
    var armedNs = newSeq[int64](armed.len)
    for i, m in armed:
      armedNs[i] = m.epochNanoSeconds
    try:
      state.traceWriter[].writeTimeDecision(armedNs, advanceTo.epochNanoSeconds)
    except IOError as exc:
      raiseSimEngineError(SimFailureKind.ProtocolViolation,
        "simulation trace write failure: " & exc.msg)
  advanceTo

proc simDecideIo*(state: SimEngineState, cp: IoOutcomePoint): IoDecision
                  {.raises: [SimEngineError].} =
  ## Asks the oracle's `decideIo` closure to resolve one I/O outcome
  ## (3.3). No live producer wires this before the transport seam (S10);
  ## S6 exercises it with hand-built `IoOutcomePoint` values to validate
  ## the choice-point shape ahead of the seam that will drive it. An
  ## oracle error is a structured simulation-protocol violation, raised
  ## directly as a typed `SimEngineError`, the same discipline
  ## `simDecideBatch`/`simDecideTimeAdvance` already use.
  state.noteDecision()
  let decision = state.oracle.decideIoImpl(cp)
  if decision.isErr:
    raiseSimEngineError(SimFailureKind.ProtocolViolation,
      "simulation oracle error: " & decision.error.msg)
  result = decision.get()
  if result.outcome == SimIoOutcome.Ok:
    let minBytes = if cp.maxBytes == 0: 0 else: 1
    if result.bytes < minBytes or result.bytes > cp.maxBytes:
      raiseSimEngineError(SimFailureKind.ProtocolViolation,
        "simulation I/O violation: decideIo returned " &
        $result.bytes & " bytes, outside the legal " & $minBytes & ".." &
        $cp.maxBytes & " range for this request (a 0-byte answer against " &
        "a positive request would be read downstream as EOF)")
  elif result.fault notin cp.faults:
    raiseSimEngineError(SimFailureKind.ProtocolViolation,
      "simulation I/O violation: decideIo returned fault " &
      $result.fault & ", outside the offered " & $cp.faults &
      " menu for this request")
  if not state.traceWriter.isNil:
    var faultNames = newSeq[string]()
    for f in cp.faults:
      faultNames.add toLowerAscii($f)
    let outcomeStr = if result.outcome == SimIoOutcome.Ok: "ok" else: "fault"
    let bytes = if result.outcome == SimIoOutcome.Ok: result.bytes else: 0
    let faultStr =
      if result.outcome == SimIoOutcome.Fault: toLowerAscii($result.fault)
      else: ""
    try:
      state.traceWriter[].writeIoDecision(cp.trigger, cp.endpoint,
        toLowerAscii($cp.op), cp.maxBytes, faultNames, outcomeStr, bytes,
        faultStr)
    except IOError as exc:
      raiseSimEngineError(SimFailureKind.ProtocolViolation,
        "simulation trace write failure: " & exc.msg)

proc simFaultToError*(fault: SimFault): OSErrorCode {.inline.} =
  ## Maps a scripted `SimFault` onto the real `OSErrorCode` the
  ## transport layer's error-classification helpers already recognize,
  ## so a sim-mode fault flows through the exact same
  ## `isConnResetError`/`setReadError`/`handleError` logic a real error
  ## would (RFC 0003 3.2 N4). Each member gets its own arm here rather
  ## than an `else`, so a new `SimFault` forces a compile error here
  ## instead of silently falling through. This module is platform-
  ## neutral (unlike `stream.nim`'s POSIX-only seam), so the code is
  ## named per platform the way `transports/common.nim` does throughout:
  ## Windows has no bare `ECONNRESET`, only `WSAECONNRESET`.
  case fault
  of SimFault.Reset:
    when defined(windows):
      oserrno.WSAECONNRESET
    else:
      oserrno.ECONNRESET
  of SimFault.Drop, SimFault.Duplicate, SimFault.Reorder:
    raiseAssert "simFaultToError(): " & $fault & " has no OS error " &
      "translation - it is a delivery-fate fault (RFC 0003 6, S12b) " &
      "the datagram write path resolves before any error would reach " &
      "the caller, so it should never reach this translation"

proc simMintStreamPair*(state: SimEngineState): tuple[a, b: int] =
  ## Mints a connected pair of sim stream endpoints (RFC 0003 3.2's
  ## sim-native connection setup, S11a): two sim fds, each wired as
  ## the other's peer, each carrying its own real `SimEndpointId`.
  ## `chronos/transports/stream.nim`'s `simStreamPair` is the sole
  ## production caller, wrapping the two fds in `StreamTransport`s;
  ## connection establishment itself asks nothing of `decideBatch`/
  ## `decideIo` - only the read/write path the pair now shares does.
  let
    fdA = state.mintSimFd()
    fdB = state.mintSimFd()
  state.streamEndpoints[fdA] = SimStreamEndpoint(
    id: state.mintSimEndpointId(), peerFd: fdB, inbound: initDeque[byte]())
  state.streamEndpoints[fdB] = SimStreamEndpoint(
    id: state.mintSimEndpointId(), peerFd: fdA, inbound: initDeque[byte]())
  (fdA, fdB)

proc simStreamTake(state: SimEngineState, fd: int, n: int, data: pointer) =
  ## Copies exactly `n` bytes (already validated `<= inbound.len` by
  ## the caller) out of `fd`'s own inbound queue into `data`,
  ## consuming them.
  if n > 0:
    var ep = state.streamEndpoints.getOrDefault(fd)
    let dst = cast[ptr UncheckedArray[byte]](data)
    for i in 0 ..< n:
      dst[i] = ep.inbound.popFirst()
    state.streamEndpoints[fd] = ep

proc simFlushInterest*(state: SimEngineState, fd: int):
    tuple[reader, writer: InternalAsyncCallback] =
  ## Pops and clears `fd`'s armed reader/writer interest (the
  ## `closeSocket` sim teardown-flush judgment call, S4-deferred and
  ## settled here at S11a): a sim-minted fd has no selector-backed
  ## `flushPendingReaderWriter` to run, but a reader or writer left
  ## armed when its fd closes would otherwise wait forever for an
  ## event that will never arrive, since nothing else will ever
  ## deliver one for a fd this run just tore down. The caller
  ## (`closeSocket`) enqueues whatever comes back onto its own
  ## callback queue, the same "fire it now, with whatever error state
  ## the transport is already in" real mode gives a closing fd's
  ## pending reader/writer.
  result = (state.interest.getOrDefault(fd).reader,
            state.interest.getOrDefault(fd).writer)
  state.interest.del(fd)

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

proc simMarkReadyOnce(state: SimEngineState, fd: int,
                       direction: SimReadyDirection) =
  ## Enqueues a `Readiness` event only if this fd/direction's currently
  ## armed callback does not already have one waiting for delivery -
  ## the sim analogue of level-triggered readiness: a socket already
  ## "ready" does not get re-notified until it is drained or its
  ## interest changes. Without this, several writes landing before the
  ## first delivery is processed would fire the same reader callback
  ## more times than there is data left to justify, breaking
  ## `readerCb`'s "we were notified, so there must be progress"
  ## invariant. A no-op (like `simMarkReady` itself would assert on)
  ## when nothing is armed in `direction`.
  let entry = state.interest.getOrDefault(fd)
  let cb = if direction == SimReadyDirection.Read: entry.reader else: entry.writer
  if isNil(cb.function):
    return
  for r in state.readyQueue:
    if r.event.kind == SimEventKind.Readiness and
       uint32(r.event.source) == uint32(fd) and
       r.callback.function == cb.function and r.callback.udata == cb.udata:
      return
  discard state.simMarkReady(fd, direction)

proc simStreamDeliver(state: SimEngineState, fd: int, data: pointer, n: int) =
  ## Appends `n` bytes from `data` to the connected peer's inbound
  ## queue and, if the peer has an armed reader waiting, schedules its
  ## delivery through the unmodified registration-routing machinery
  ## (S4) - the first production source `simMarkReady` gets, per its
  ## own docstring.
  let peerFd = state.streamEndpoints.getOrDefault(fd).peerFd
  if n > 0:
    var peer = state.streamEndpoints.getOrDefault(peerFd)
    let src = cast[ptr UncheckedArray[byte]](data)
    for i in 0 ..< n:
      peer.inbound.addLast(src[i])
    state.streamEndpoints[peerFd] = peer
  state.simMarkReadyOnce(peerFd, SimReadyDirection.Read)

proc simStreamIo*(state: SimEngineState, fd: int, op: SimIoOp, data: pointer,
                   maxBytes: int): tuple[res: int, err: OSErrorCode]
                  {.raises: [SimEngineError].} =
  ## The sim stream seam's full orchestration (RFC 0003 3.2 N4, S11a):
  ## for a fd with a live `SimNet` endpoint, real content moves through
  ## the endpoint pair's in-memory queue - a read with nothing queued
  ## and a peer that has not half-closed answers "would block" without
  ## consulting the oracle at all (a structural fact, not a choice);
  ## `decideIo` still adjudicates the byte count (and, for a scripted
  ## oracle, a fault) once content is or could be available, S10's
  ## choice-point discipline unchanged. A fd with no live endpoint (a
  ## bare minted fd, e.g. `testsimstream.nim`'s probes) falls back to
  ## S10's original scripted-oracle-only behavior: `decideIo` alone
  ## picks a byte count and no content is copied.
  if fd notin state.streamEndpoints:
    let decision = state.simDecideIo(IoOutcomePoint(
      trigger: SimEventId(0), endpoint: SimEndpointId(uint32(fd)),
      op: op, maxBytes: maxBytes, faults: {SimFault.Reset}))
    return case decision.outcome
      of SimIoOutcome.Ok: (decision.bytes, OSErrorCode(0))
      of SimIoOutcome.Fault: (-1, simFaultToError(decision.fault))

  let endpointId = state.streamEndpoints.getOrDefault(fd).id
  case op
  of SimIoOp.Write:
    let decision = state.simDecideIo(IoOutcomePoint(
      trigger: SimEventId(0), endpoint: endpointId, op: op,
      maxBytes: maxBytes, faults: {SimFault.Reset}))
    case decision.outcome
    of SimIoOutcome.Ok:
      state.simStreamDeliver(fd, data, decision.bytes)
      (decision.bytes, OSErrorCode(0))
    of SimIoOutcome.Fault:
      (-1, simFaultToError(decision.fault))
  of SimIoOp.Read:
    let endpoint = state.streamEndpoints.getOrDefault(fd)
    let avail = endpoint.inbound.len
    if avail == 0 and not endpoint.peerClosed:
      when defined(windows):
        return (-1, oserrno.WSAEWOULDBLOCK)
      else:
        return (-1, oserrno.EWOULDBLOCK)
    let decision = state.simDecideIo(IoOutcomePoint(
      trigger: SimEventId(0), endpoint: endpointId, op: op,
      maxBytes: min(maxBytes, avail), faults: {SimFault.Reset}))
    case decision.outcome
    of SimIoOutcome.Ok:
      state.simStreamTake(fd, decision.bytes, data)
      if decision.bytes < avail:
        # A partial read: bytes remain queued in `inbound`. Real sockets
        # stay level-triggered (readerCb's own comment: "another callback
        # will happen automatically"), driven by the OS selector
        # re-noticing unread data on its own; the sim engine has no such
        # selector, so it has to re-arm the reader itself or the leftover
        # bytes wait for an event that will now never come.
        state.simMarkReadyOnce(fd, SimReadyDirection.Read)
      (decision.bytes, OSErrorCode(0))
    of SimIoOutcome.Fault:
      (-1, simFaultToError(decision.fault))

proc mintSimDatagramPair*(state: SimEngineState, localA, localB: seq[byte]):
    tuple[a, b: int] =
  ## Mints a connected pair of sim datagram endpoints (RFC 0003 6, S12b),
  ## the datagram-native counterpart to `simMintStreamPair`: two sim fds,
  ## each wired as the other's peer, each carrying its own address (raw
  ## OS-level bytes, opaque to this layer) and its own real
  ## `SimEndpointId`. `chronos/transports/datagram.nim`'s
  ## `simDatagramPair` is the sole production caller.
  let
    fdA = state.mintSimFd()
    fdB = state.mintSimFd()
  state.datagramEndpoints[fdA] = SimDatagramEndpoint(
    id: state.mintSimEndpointId(), peerFd: fdB, localAddr: localA,
    inbound: initDeque[SimDatagramMessage]())
  state.datagramEndpoints[fdB] = SimDatagramEndpoint(
    id: state.mintSimEndpointId(), peerFd: fdA, localAddr: localB,
    inbound: initDeque[SimDatagramMessage]())
  (fdA, fdB)

proc simDatagramTake(state: SimEngineState, fd: int, n: int,
                      data: pointer): seq[byte] =
  ## Pops exactly one queued datagram off `fd`'s own inbound queue
  ## (message-oriented: never a byte slice spanning two queued
  ## datagrams) and copies up to `n` (already validated `<=` that
  ## message's length by the caller) bytes of it into `data`, discarding
  ## whatever is left of that message unread - the same truncate-and-
  ## drop convention a real `recvfrom()` uses when the caller's buffer is
  ## smaller than the datagram. Returns the message's sender address for
  ## the caller to report back, the sim analogue of `recvfrom()`'s
  ## `fromaddr` out-param.
  var ep = state.datagramEndpoints.getOrDefault(fd)
  let msg = ep.inbound.popFirst()
  state.datagramEndpoints[fd] = ep
  if n > 0 and msg.data.len > 0:
    let dst = cast[ptr UncheckedArray[byte]](data)
    for i in 0 ..< min(n, msg.data.len):
      dst[i] = msg.data[i]
  msg.fromAddr

proc simDatagramDeliver(state: SimEngineState, fd: int, data: pointer, n: int,
                         reorder: bool) =
  ## Queues one whole datagram (`n` bytes copied out of `data`, this
  ## message's own atomic unit - no leftover-byte bookkeeping the way
  ## `simStreamDeliver` needs) onto the peer's inbound queue, tagged with
  ## the sender's own address, and wakes an already-armed peer reader
  ## (`simMarkReadyOnce`, unchanged from S11a). `reorder`, when true and
  ## the peer already has a message queued, inserts at the front instead
  ## of the back - this write is delivered to the peer before whatever
  ## it already had pending, the RFC 0003 6 S12b reorder fault's
  ## placement (write-side, per-op `decideIo`; see `simDatagramIo`'s
  ## docstring for the full rationale). A no-op reorder (falls back to
  ## normal back-of-queue delivery) when nothing is pending yet - there
  ## is nothing to arrive out of order against.
  let peerFd = state.datagramEndpoints.getOrDefault(fd).peerFd
  var payload = newSeq[byte](n)
  if n > 0:
    let src = cast[ptr UncheckedArray[byte]](data)
    for i in 0 ..< n:
      payload[i] = src[i]
  let msg = SimDatagramMessage(data: payload,
    fromAddr: state.datagramEndpoints.getOrDefault(fd).localAddr)
  var peer = state.datagramEndpoints.getOrDefault(peerFd)
  if reorder and peer.inbound.len > 0:
    peer.inbound.addFirst(msg)
  else:
    peer.inbound.addLast(msg)
  state.datagramEndpoints[peerFd] = peer
  state.simMarkReadyOnce(peerFd, SimReadyDirection.Read)

proc simDatagramIo*(state: SimEngineState, fd: int, op: SimIoOp, data: pointer,
                     maxBytes: int):
    tuple[res: int, err: OSErrorCode, fromAddr: seq[byte]]
    {.raises: [SimEngineError].} =
  ## The sim datagram seam's orchestration (RFC 0003 6, slices S12a/
  ## S12b). A fd with no live endpoint (a bare minted fd, e.g.
  ## `testsimdatagram.nim`'s seam probes) keeps S12a's original
  ## fallback: `decideIo` alone picks a byte count or fault, `data` is
  ## never touched, no address is ever reported.
  ##
  ## A fd with a live endpoint routes through the endpoint table: a read
  ## with nothing queued answers "would block" without consulting the
  ## oracle at all (the same structural-fact rule `simStreamIo` already
  ## applies to an empty inbound queue) - unlike a stream's EOF case,
  ## there is no "peer closed" fallback to check, since datagrams have
  ## no half-close/EOF concept. Once a message is queued, `decideIo`
  ## adjudicates its `Reset` fault (S12b): reset is a recv-side choice,
  ## mirroring the real platform's ECONNRESET-after-ICMP-unreachable
  ## behavior (ejected here rather than at write time because the
  ## fault's whole point is "the peer is unreachable, discovered on the
  ## next attempt to receive from it" - `readDatagramLoop`'s own error
  ## path is what actually surfaces it to a caller). Drop/duplicate/
  ## reorder (S12b) are write-side choices instead: unlike Reset, none
  ## of them fail the local `sendto()`-equivalent call (real UDP never
  ## fails a send over packet loss), so they cannot flow through the
  ## generic `IoDecision.Fault` branch a stream write already reuses for
  ## Reset - `simDatagramIo`'s write branch intercepts each by name
  ## before it would otherwise translate to an `OSErrorCode`.
  if fd notin state.datagramEndpoints:
    let decision = state.simDecideIo(IoOutcomePoint(
      trigger: SimEventId(0), endpoint: SimEndpointId(uint32(fd)), op: op,
      maxBytes: maxBytes, faults: {SimFault.Reset}))
    return case decision.outcome
      of SimIoOutcome.Ok: (decision.bytes, OSErrorCode(0), newSeq[byte]())
      of SimIoOutcome.Fault:
        (-1, simFaultToError(decision.fault), newSeq[byte]())

  let endpointId = state.datagramEndpoints.getOrDefault(fd).id
  case op
  of SimIoOp.Read:
    let avail = state.datagramEndpoints.getOrDefault(fd).inbound.len
    if avail == 0:
      when defined(windows):
        return (-1, oserrno.WSAEWOULDBLOCK, newSeq[byte]())
      else:
        return (-1, oserrno.EWOULDBLOCK, newSeq[byte]())
    let msgLen = state.datagramEndpoints.getOrDefault(fd).inbound[0].data.len
    let decision = state.simDecideIo(IoOutcomePoint(
      trigger: SimEventId(0), endpoint: endpointId, op: op,
      maxBytes: min(maxBytes, msgLen), faults: {SimFault.Reset}))
    case decision.outcome
    of SimIoOutcome.Ok:
      let fromAddr = state.simDatagramTake(fd, decision.bytes, data)
      if state.datagramEndpoints.getOrDefault(fd).inbound.len > 0:
        # More than one datagram was queued: level-triggered readiness
        # (S11a's `simMarkReadyOnce` rule) needs a fresh event for the
        # rest, the same re-arm `simStreamIo` performs for leftover
        # bytes of a partially-read stream - here, leftover *messages*.
        state.simMarkReadyOnce(fd, SimReadyDirection.Read)
      (decision.bytes, OSErrorCode(0), fromAddr)
    of SimIoOutcome.Fault:
      (-1, simFaultToError(decision.fault), newSeq[byte]())
  of SimIoOp.Write:
    let decision = state.simDecideIo(IoOutcomePoint(
      trigger: SimEventId(0), endpoint: endpointId, op: op,
      maxBytes: maxBytes,
      faults: {SimFault.Drop, SimFault.Duplicate, SimFault.Reorder}))
    case decision.outcome
    of SimIoOutcome.Ok:
      state.simDatagramDeliver(fd, data, decision.bytes, reorder = false)
      (decision.bytes, OSErrorCode(0), newSeq[byte]())
    of SimIoOutcome.Fault:
      case decision.fault
      of SimFault.Reset:
        (-1, simFaultToError(SimFault.Reset), newSeq[byte]())
      of SimFault.Drop:
        # Silently vanishes: the local send still succeeds (real UDP
        # never fails a send over packet loss), only delivery is
        # skipped.
        (maxBytes, OSErrorCode(0), newSeq[byte]())
      of SimFault.Duplicate:
        state.simDatagramDeliver(fd, data, maxBytes, reorder = false)
        state.simDatagramDeliver(fd, data, maxBytes, reorder = false)
        (maxBytes, OSErrorCode(0), newSeq[byte]())
      of SimFault.Reorder:
        state.simDatagramDeliver(fd, data, maxBytes, reorder = true)
        (maxBytes, OSErrorCode(0), newSeq[byte]())

proc simStreamHalfClose*(state: SimEngineState, fd: int) =
  ## Sim-mode half-close (RFC 0003 3.2: `closeWait`/`shutdownWait`
  ## deliver EOF to the peer, this slice's RED-phase design): marks
  ## the peer's endpoint `peerClosed`, so its next read reports EOF
  ## once its `inbound` queue drains, and - if that queue is already
  ## empty and a reader is armed - wakes it immediately rather than
  ## leaving it waiting for an event that will now never come. A no-op
  ## for a fd with no live endpoint (a bare minted fd never wired
  ## through `simMintStreamPair`), so `close()`'s unconditional sim
  ## hook stays safe for non-`SimNet` sim transports too.
  if fd notin state.streamEndpoints:
    return
  let peerFd = state.streamEndpoints.getOrDefault(fd).peerFd
  var peer = state.streamEndpoints.getOrDefault(peerFd)
  peer.peerClosed = true
  let inboundEmpty = peer.inbound.len == 0
  state.streamEndpoints[peerFd] = peer
  if inboundEmpty:
    state.simMarkReadyOnce(peerFd, SimReadyDirection.Read)

proc simScheduleArrival*(state: SimEngineState): SimEventId =
  ## Schedules a bare `Arrival` event marker (RFC 0003 3.5/3.6):
  ## delivery drains through `processThreadCallbacks` unconditionally.
  ## `simProducer` (S13) still calls this - once, on the false-to-true
  ## `waking` transition - to mint the event `decideBatch` schedules;
  ## the actor identity and payload it carries live in the real
  ## cross-thread `threadCallbacks` MPSC queue `simProducer.post()`
  ## pushes onto directly, not in this `SimEvent`, which stays a bare
  ## marker by design: `processThreadCallbacks` already knows how to
  ## drain that queue without this event carrying a copy of its
  ## contents.
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
                      deliverable: seq[SimEvent]): BatchDecision
                     {.raises: [SimEngineError].} =
  ## Asks the oracle to choose a delivery order among `deliverable`
  ## (RFC 0003 3.3/3.5). Validates every returned id is a member of
  ## `deliverable`, appearing at most once - an oracle answer naming an
  ## unknown or duplicate id is a structured simulation-protocol
  ## violation, raised directly as a typed `SimEngineError`, the same
  ## discipline `simDecideTimeAdvance` already uses.
  state.noteDecision()
  let decision = state.oracle.decideBatchImpl(
    SelectBatchPoint(deliverable: deliverable))
  if decision.isErr:
    raiseSimEngineError(SimFailureKind.ProtocolViolation,
      "simulation oracle error: " & decision.error.msg)
  result = decision.get()
  var seen = initHashSet[uint64]()
  for id in result.order:
    var found = false
    for ev in deliverable:
      if ev.id == id:
        found = true
        break
    if not found:
      raiseSimEngineError(SimFailureKind.ProtocolViolation,
        "simulation batch violation: decideBatch named an id " &
        "not in deliverable: " & $id)
    if uint64(id) in seen:
      raiseSimEngineError(SimFailureKind.ProtocolViolation,
        "simulation batch violation: decideBatch named id " &
        $id & " more than once")
    seen.incl(uint64(id))
  if not state.traceWriter.isNil:
    var deliverableIds = newSeq[SimEventId](deliverable.len)
    for i, ev in deliverable:
      deliverableIds[i] = ev.id
    try:
      state.traceWriter[].writeBatchDecision(deliverableIds, result.order)
    except IOError as exc:
      raiseSimEngineError(SimFailureKind.ProtocolViolation,
        "simulation trace write failure: " & exc.msg)

proc simTakeDelivery*(state: SimEngineState, id: SimEventId):
    tuple[kind: SimEventKind, callback: InternalAsyncCallback]
    {.raises: [SimEngineError].} =
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
  raiseSimEngineError(SimFailureKind.ProtocolViolation,
    "simTakeDelivery(): unknown id " & $id &
    " - validated ids must exist in the pending event set")
