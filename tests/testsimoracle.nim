#                  Tonalli Test Suite
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## Tests for `chronos/internal/simengine.nim`'s `RandomOracle`: a seeded
## oracle whose decisions are deterministic in the seed (RFC 0003 3.3,
## 3.7, slice S5) and, combined with `simtrace.nim`'s decision-log writer,
## produce byte-identical logs for the same seed and differing logs for
## different seeds.
##
## Also S6's interface freeze gate (RFC 0003 3.3, 6/S6): `decideIo`/
## `IoOutcomePoint` exercised with hand-built values ahead of S10's
## transport seam, and a throwaway priority-permutation oracle (the PCT
## primitive) proving the `SimOracle` interface admits a structurally
## different consumer than the blind random/replay oracles.

import unittest2
import std/[os, algorithm, tables, strutils]
import results
import ../chronos/timer
import ../chronos/internal/simengine
import ../chronos/internal/simtrace

{.used.}

proc deliverableOf(ids: openArray[uint64]): seq[SimEvent] =
  result = newSeq[SimEvent](ids.len)
  for i, id in ids:
    result[i] = SimEvent(id: SimEventId(id), kind: SimEventKind.Readiness,
                          source: SimEndpointId(0'u32))

proc sorted(ids: seq[SimEventId]): seq[SimEventId] =
  result = ids
  result.sort(proc(a, b: SimEventId): int = cmp(uint64(a), uint64(b)))

suite "sim RandomOracle":
  test "the same seed produces the same batch order":
    let deliverable = deliverableOf([1'u64, 2, 3, 4, 5, 6, 7, 8])
    let stateA = newSimEngineState(oracle = RandomOracle(42'u64))
    let stateB = newSimEngineState(oracle = RandomOracle(42'u64))
    let orderA = stateA.simDecideBatch(deliverable).order
    let orderB = stateB.simDecideBatch(deliverable).order
    check orderA == orderB

  test "different seeds produce different batch orders":
    let deliverable = deliverableOf([1'u64, 2, 3, 4, 5, 6, 7, 8])
    let stateA = newSimEngineState(oracle = RandomOracle(1'u64))
    let stateB = newSimEngineState(oracle = RandomOracle(2'u64))
    let orderA = stateA.simDecideBatch(deliverable).order
    let orderB = stateB.simDecideBatch(deliverable).order
    check orderA != orderB

  test "the decided order is a permutation of the deliverable ids":
    let deliverable = deliverableOf([1'u64, 2, 3, 4, 5])
    let state = newSimEngineState(oracle = RandomOracle(7'u64))
    let order = state.simDecideBatch(deliverable).order
    check sorted(order) == sorted(@[SimEventId(1'u64), SimEventId(2'u64),
      SimEventId(3'u64), SimEventId(4'u64), SimEventId(5'u64)])

  test "decideTime advances to the earliest armed deadline":
    let armed = @[Moment.init(500, Nanosecond), Moment.init(900, Nanosecond)]
    let state = newSimEngineState(oracle = RandomOracle(3'u64))
    let advanceTo = state.simDecideTimeAdvance(armed, Moment.init(0, Nanosecond))
    check advanceTo == armed[0]

proc traceForSeed(seed: uint64, path: string): string =
  let deliverable = deliverableOf([1'u64, 2, 3, 4, 5, 6, 7, 8])
  let state = newSimEngineState(oracle = RandomOracle(seed))
  let order = state.simDecideBatch(deliverable).order
  var writer = openSimTraceWriter(path, seed = seed,

    decisionBudget = 10_000,

    timeBudgetNanoseconds = 3_600_000_000_000'i64)
  writer.writeBatchDecision(
    @[SimEventId(1'u64), SimEventId(2'u64), SimEventId(3'u64),
      SimEventId(4'u64), SimEventId(5'u64), SimEventId(6'u64),
      SimEventId(7'u64), SimEventId(8'u64)], order)
  writer.close()
  readFile(path)

suite "sim decision-log determinism":
  test "two runs of the same seed produce identical logs":
    let pathA = getTempDir() / "chronos-simoracle-same-a.ndjson"
    let pathB = getTempDir() / "chronos-simoracle-same-b.ndjson"
    let logA = traceForSeed(42'u64, pathA)
    let logB = traceForSeed(42'u64, pathB)
    check logA == logB
    removeFile(pathA)
    removeFile(pathB)

  test "different seeds produce different logs":
    let pathA = getTempDir() / "chronos-simoracle-diff-a.ndjson"
    let pathC = getTempDir() / "chronos-simoracle-diff-c.ndjson"
    let logA = traceForSeed(1'u64, pathA)
    let logC = traceForSeed(2'u64, pathC)
    check logA != logC
    removeFile(pathA)
    removeFile(pathC)

# --- S6: decideIo/IoOutcomePoint, completing the decideBatch/decideIo/
# decideTime triple (RFC 0003 3.3 D2). No live producer exists before S10;
# these exercise the choice point with hand-built `IoOutcomePoint` values.

suite "sim decideIo and IoOutcomePoint":
  test "the default oracle completes fully at the requested size":
    let state = newSimEngineState()
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Read, maxBytes: 256,
      faults: {})
    let decision = state.simDecideIo(cp)
    check decision.outcome == SimIoOutcome.Ok
    check decision.bytes == 256

  test "a scripted oracle can return a fault outcome":
    let oracle = newSimOracle(defaultDecideBatch,
      proc(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Reset)),
      defaultDecideTime)
    let state = newSimEngineState(oracle = oracle)
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(3'u32), op: SimIoOp.Write, maxBytes: 64,
      faults: {SimFault.Reset})
    let decision = state.simDecideIo(cp)
    check decision.outcome == SimIoOutcome.Fault
    check decision.fault == SimFault.Reset

  test "an oracle error on decideIo is reported, not silently accepted":
    let oracle = newSimOracle(defaultDecideBatch,
      proc(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        err(SimOracleError(msg: "scripted io failure")),
      defaultDecideTime)
    let state = newSimEngineState(oracle = oracle)
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Read, maxBytes: 16,
      faults: {})
    try:
      discard state.simDecideIo(cp)
      check false
    except SimEngineError as exc:
      check exc.kind == SimFailureKind.ProtocolViolation
      check "scripted io failure" in exc.msg

# --- S11b: decideIo can now complete partially. The engine validates the
# byte count an oracle returns the same way it already validates a
# decideBatch id or a decideTime advance: an out-of-range answer is a
# structured protocol violation, never a silent overrun or a spurious EOF.

suite "sim decideIo partial-outcome validation":
  test "an Ok decision exceeding maxBytes is a protocol violation":
    let oracle = newSimOracle(defaultDecideBatch,
      proc(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: cp.maxBytes + 1)),
      defaultDecideTime)
    let state = newSimEngineState(oracle = oracle)
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Read, maxBytes: 16,
      faults: {})
    try:
      discard state.simDecideIo(cp)
      check false
    except SimEngineError as exc:
      check exc.kind == SimFailureKind.ProtocolViolation
      check "17" in exc.msg and "16" in exc.msg

  test "a zero-byte Ok decision against a non-empty request is a protocol violation":
    ## Downstream stream code treats a zero-byte read/write as EOF
    ## (`readIntoBuffer`'s `res == 0` convention); a decideIo answer of 0
    ## bytes against a positive `maxBytes` would silently fabricate an
    ## EOF that never happened, so the engine rejects it here instead.
    let oracle = newSimOracle(defaultDecideBatch,
      proc(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: 0)),
      defaultDecideTime)
    let state = newSimEngineState(oracle = oracle)
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Write, maxBytes: 8,
      faults: {})
    try:
      discard state.simDecideIo(cp)
      check false
    except SimEngineError as exc:
      check exc.kind == SimFailureKind.ProtocolViolation
      check "0" in exc.msg and "8" in exc.msg

  test "a scripted oracle can complete an Ok decision partially":
    let oracle = newSimOracle(defaultDecideBatch,
      proc(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: cp.maxBytes div 2)),
      defaultDecideTime)
    let state = newSimEngineState(oracle = oracle)
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Read, maxBytes: 10,
      faults: {})
    let decision = state.simDecideIo(cp)
    check decision.outcome == SimIoOutcome.Ok
    check decision.bytes == 5

# --- A Fault decision's `fault` must also be a member of the offered
# `cp.faults` menu, the same membership rule the Ok branch already
# enforces on `bytes`; an unlisted fault (a stream write's empty menu is
# the degenerate case) would otherwise reach `simFaultToError` unchecked.

suite "sim decideIo fault-menu validation":
  test "a Fault decision naming a fault outside the offered menu is a protocol violation":
    let oracle = newSimOracle(defaultDecideBatch,
      proc(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Drop)),
      defaultDecideTime)
    let state = newSimEngineState(oracle = oracle)
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Write, maxBytes: 16,
      faults: {})
    try:
      discard state.simDecideIo(cp)
      check false
    except SimEngineError as exc:
      check exc.kind == SimFailureKind.ProtocolViolation
      check "drop" in toLowerAscii(exc.msg)

  test "a Fault decision naming a fault inside the offered menu is accepted":
    let oracle = newSimOracle(defaultDecideBatch,
      proc(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Reset)),
      defaultDecideTime)
    let state = newSimEngineState(oracle = oracle)
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Write, maxBytes: 16,
      faults: {SimFault.Reset})
    let decision = state.simDecideIo(cp)
    check decision.outcome == SimIoOutcome.Fault
    check decision.fault == SimFault.Reset

suite "sim RandomOracle partial I/O":
  test "RandomOracle's decideIo answers stay within 1..maxBytes":
    for seed in 0'u64 .. 50'u64:
      let state = newSimEngineState(oracle = RandomOracle(seed))
      let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
        endpoint: SimEndpointId(0'u32), op: SimIoOp.Read, maxBytes: 32,
        faults: {})
      let decision = state.simDecideIo(cp)
      check decision.outcome == SimIoOutcome.Ok
      check decision.bytes >= 1
      check decision.bytes <= 32

  test "RandomOracle's decideIo picks partial completions for some seeds":
    var sawPartial = false
    var sawFull = false
    for seed in 0'u64 .. 50'u64:
      let state = newSimEngineState(oracle = RandomOracle(seed))
      let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
        endpoint: SimEndpointId(0'u32), op: SimIoOp.Write, maxBytes: 32,
        faults: {})
      let decision = state.simDecideIo(cp)
      if decision.bytes < 32: sawPartial = true
      if decision.bytes == 32: sawFull = true
    check sawPartial
    check sawFull

  test "RandomOracle's decideIo is deterministic in the seed":
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Read, maxBytes: 32,
      faults: {})
    let stateA = newSimEngineState(oracle = RandomOracle(99'u64))
    let stateB = newSimEngineState(oracle = RandomOracle(99'u64))
    check stateA.simDecideIo(cp).bytes == stateB.simDecideIo(cp).bytes

  test "RandomOracle's decideIo always completes fully when maxBytes is 1":
    let state = newSimEngineState(oracle = RandomOracle(5'u64))
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(0'u32), op: SimIoOp.Read, maxBytes: 1,
      faults: {})
    check state.simDecideIo(cp).bytes == 1

# --- S6: the interface freeze gate. A structurally different consumer -
# a priority-permutation oracle (the PCT primitive, Burckhardt et al.) -
# built entirely from typed choice-point data, never touching asyncengine
# or simengine. Throwaway spike wiring (RFC 0003 3.3, 6/S6): it exists to
# validate D2's shape, not to ship as a real exploration oracle (issue #10).

proc newPctOracle(priorityOf: proc(source: SimEndpointId, kind: SimEventKind):
    int {.gcsafe, raises: [].}): SimOracle =
  ## A minimal PCT primitive: `decideBatch` always schedules the
  ## highest-priority deliverable event first (ties broken by id for
  ## determinism). Scheduling an event is a priority-change point in the
  ## Burckhardt sense: the winner's priority drops below every other
  ## source present in that same decision, so a later decision over the
  ## same sources is guaranteed to pick someone else, all from the
  ## closure captures `newSimOracle`'s consumers already use for
  ## statefulness (3.3's "Statefulness" note).
  var overrides = initTable[uint32, int]()
  proc currentPriority(ev: SimEvent): int =
    overrides.getOrDefault(uint32(ev.source), priorityOf(ev.source, ev.kind))
  proc decideBatch(cp: SelectBatchPoint):
      Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
    var scored = cp.deliverable
    scored.sort(proc(x, y: SimEvent): int =
      let px = currentPriority(x)
      let py = currentPriority(y)
      if px != py: cmp(py, px)
      else: cmp(uint64(x.id), uint64(y.id)))
    if scored.len > 1:
      let winner = scored[0]
      var floor = currentPriority(scored[1])
      for i in 2 ..< scored.len:
        let p = currentPriority(scored[i])
        if p < floor: floor = p
      overrides[uint32(winner.source)] = floor - 1
    var order = newSeq[SimEventId](scored.len)
    for i, ev in scored:
      order[i] = ev.id
    ok(BatchDecision(order: order))
  newSimOracle(decideBatch, defaultDecideIo, defaultDecideTime)

suite "sim PCT-primitive oracle (interface freeze gate)":
  test "always prefers endpoint A's events":
    let endpointA = SimEndpointId(1'u32)
    let endpointB = SimEndpointId(2'u32)
    proc priorityOf(source: SimEndpointId, kind: SimEventKind): int {.gcsafe.} =
      if source == endpointA: 10 else: 1
    let oracle = newPctOracle(priorityOf)
    let state = newSimEngineState(oracle = oracle)
    let deliverable = @[
      SimEvent(id: SimEventId(1'u64), kind: SimEventKind.Readiness, source: endpointB),
      SimEvent(id: SimEventId(2'u64), kind: SimEventKind.Readiness, source: endpointA),
      SimEvent(id: SimEventId(3'u64), kind: SimEventKind.Readiness, source: endpointB),
      SimEvent(id: SimEventId(4'u64), kind: SimEventKind.Readiness, source: endpointA)]
    let decision = state.simDecideBatch(deliverable)
    check decision.order == @[SimEventId(2'u64), SimEventId(4'u64),
                               SimEventId(1'u64), SimEventId(3'u64)]

  test "deprioritizes arrival batches":
    let source = SimEndpointId(0'u32)
    proc priorityOf(source: SimEndpointId, kind: SimEventKind): int {.gcsafe.} =
      if kind == SimEventKind.Arrival: -100 else: 5
    let oracle = newPctOracle(priorityOf)
    let state = newSimEngineState(oracle = oracle)
    let deliverable = @[
      SimEvent(id: SimEventId(1'u64), kind: SimEventKind.Arrival, source: source),
      SimEvent(id: SimEventId(2'u64), kind: SimEventKind.Readiness, source: source),
      SimEvent(id: SimEventId(3'u64), kind: SimEventKind.Arrival, source: source),
      SimEvent(id: SimEventId(4'u64), kind: SimEventKind.Readiness, source: source)]
    let decision = state.simDecideBatch(deliverable)
    check decision.order == @[SimEventId(2'u64), SimEventId(4'u64),
                               SimEventId(1'u64), SimEventId(3'u64)]

  test "a priority-change point lowers the just-scheduled source for the next decision":
    let endpointA = SimEndpointId(1'u32)
    let endpointB = SimEndpointId(2'u32)
    proc priorityOf(source: SimEndpointId, kind: SimEventKind): int {.gcsafe.} =
      if source == endpointA: 10 else: 9
    let oracle = newPctOracle(priorityOf)
    let state = newSimEngineState(oracle = oracle)
    let evA = SimEvent(id: SimEventId(1'u64), kind: SimEventKind.Readiness, source: endpointA)
    let evB = SimEvent(id: SimEventId(2'u64), kind: SimEventKind.Readiness, source: endpointB)
    let firstDecision = state.simDecideBatch(@[evA, evB])
    check firstDecision.order == @[SimEventId(1'u64), SimEventId(2'u64)]
    # the change point just dropped A below B's priority (9), so the same
    # two sources flip winner on the next decision with no new choice type
    let secondDecision = state.simDecideBatch(@[evA, evB])
    check secondDecision.order == @[SimEventId(2'u64), SimEventId(1'u64)]

# --- S7: ReplayOracle, constructed from a recorded trace, verifying each
# live choice point's digest against the recorded one via the shared
# `digestOf` and returning the recorded decision (RFC 0003 3.3, 3.7).

suite "sim ReplayOracle":
  test "replay reproduces a recorded decideBatch decision":
    let path = getTempDir() / "chronos-simreplay-batch.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64,

      decisionBudget = 10_000,

      timeBudgetNanoseconds = 3_600_000_000_000'i64)
    writer.writeBatchDecision(@[SimEventId(1'u64), SimEventId(2'u64), SimEventId(3'u64)],
                               @[SimEventId(3'u64), SimEventId(1'u64), SimEventId(2'u64)])
    writer.close()
    let oracle = ReplayOracle(path)
    let state = newSimEngineState(oracle = oracle)
    let events = deliverableOf([1'u64, 2, 3])
    let decision = state.simDecideBatch(events)
    check decision.order == @[SimEventId(3'u64), SimEventId(1'u64), SimEventId(2'u64)]
    removeFile(path)

  test "replay reproduces a recorded decideTime decision":
    let path = getTempDir() / "chronos-simreplay-time.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64,

      decisionBudget = 10_000,

      timeBudgetNanoseconds = 3_600_000_000_000'i64)
    writer.writeTimeDecision(@[500'i64, 900'i64], 500'i64)
    writer.close()
    let oracle = ReplayOracle(path)
    let state = newSimEngineState(oracle = oracle)
    let armed = @[Moment.init(500, Nanosecond), Moment.init(900, Nanosecond)]
    let advanceTo = state.simDecideTimeAdvance(armed, Moment.init(0, Nanosecond))
    check advanceTo == armed[0]
    removeFile(path)

  test "replay reproduces a recorded decideIo decision":
    let path = getTempDir() / "chronos-simreplay-io.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64,

      decisionBudget = 10_000,

      timeBudgetNanoseconds = 3_600_000_000_000'i64)
    writer.writeIoDecision(SimEventId(1'u64), SimEndpointId(2'u32), "read",
                            64, newSeq[string](), "ok", 64, "")
    writer.close()
    let oracle = ReplayOracle(path)
    let state = newSimEngineState(oracle = oracle)
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(2'u32), op: SimIoOp.Read, maxBytes: 64,
      faults: {})
    let decision = state.simDecideIo(cp)
    check decision.outcome == SimIoOutcome.Ok
    check decision.bytes == 64
    removeFile(path)

  test "a live decideBatch digest mismatch fails as a named divergence":
    let path = getTempDir() / "chronos-simreplay-mismatch.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64,

      decisionBudget = 10_000,

      timeBudgetNanoseconds = 3_600_000_000_000'i64)
    writer.writeBatchDecision(@[SimEventId(1'u64), SimEventId(2'u64)],
                               @[SimEventId(2'u64), SimEventId(1'u64)])
    writer.close()
    let oracle = ReplayOracle(path)
    let state = newSimEngineState(oracle = oracle)
    # a different deliverable set than what was recorded: the live digest
    # diverges from the recorded one at index 0
    let events = deliverableOf([1'u64, 2, 3])
    try:
      discard state.simDecideBatch(events)
      check false
    except SimEngineError as exc:
      check exc.kind == SimFailureKind.ProtocolViolation
      check "replay divergence" in exc.msg
      check "index 0" in exc.msg
    removeFile(path)

  test "a payload-changed io fixture (same ids, different maxBytes) is detected divergence":
    let path = getTempDir() / "chronos-simreplay-io-mismatch.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64,

      decisionBudget = 10_000,

      timeBudgetNanoseconds = 3_600_000_000_000'i64)
    writer.writeIoDecision(SimEventId(1'u64), SimEndpointId(2'u32), "read",
                            64, newSeq[string](), "ok", 64, "")
    writer.close()
    let oracle = ReplayOracle(path)
    let state = newSimEngineState(oracle = oracle)
    # same trigger/endpoint/op/faults as the fixture, but a different
    # maxBytes: the payload digest diverges even though every id matches
    let cp = IoOutcomePoint(trigger: SimEventId(1'u64),
      endpoint: SimEndpointId(2'u32), op: SimIoOp.Read, maxBytes: 128,
      faults: {})
    try:
      discard state.simDecideIo(cp)
      check false
    except SimEngineError as exc:
      check exc.kind == SimFailureKind.ProtocolViolation
      check "replay divergence" in exc.msg
    removeFile(path)

  test "replay exhaustion is reported, not a silent default decision":
    let path = getTempDir() / "chronos-simreplay-exhausted.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64,

      decisionBudget = 10_000,

      timeBudgetNanoseconds = 3_600_000_000_000'i64)
    writer.writeBatchDecision(@[SimEventId(1'u64)], @[SimEventId(1'u64)])
    writer.close()
    let oracle = ReplayOracle(path)
    let state = newSimEngineState(oracle = oracle)
    let events = deliverableOf([1'u64])
    discard state.simDecideBatch(events)   # consumes the sole recorded decision
    try:
      discard state.simDecideBatch(events)
      check false
    except SimEngineError as exc:
      check exc.kind == SimFailureKind.ProtocolViolation
      check "exhausted" in exc.msg
    removeFile(path)

  test "a recorded-kind mismatch names both the recorded and live choice points":
    let path = getTempDir() / "chronos-simreplay-kind-mismatch.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64,

      decisionBudget = 10_000,

      timeBudgetNanoseconds = 3_600_000_000_000'i64)
    writer.writeTimeDecision(@[100'i64], 100'i64)
    writer.close()
    let oracle = ReplayOracle(path)
    let state = newSimEngineState(oracle = oracle)
    let events = deliverableOf([1'u64])
    try:
      discard state.simDecideBatch(events)
      check false
    except SimEngineError as exc:
      check exc.kind == SimFailureKind.ProtocolViolation
      check "Time" in exc.msg
      check "Batch" in exc.msg
    removeFile(path)

  test "a mismatched trace version is refused at construction":
    let path = getTempDir() / "chronos-simreplay-badversion.ndjson"
    writeFile(path,
      "{\"trace\":\"chronos-sim\",\"v\":99,\"seed\":1,\"commit\":\"\"," &
      "\"config\":\"\"}\n")
    expect SimTraceReadError:
      discard ReplayOracle(path)
    removeFile(path)
