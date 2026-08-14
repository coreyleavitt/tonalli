#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/internal/simengine.nim`'s `RandomOracle`: a seeded
## oracle whose decisions are deterministic in the seed (RFC 0003 3.3,
## 3.7, slice S5) and, combined with `simtrace.nim`'s decision-log writer,
## produce byte-identical logs for the same seed and differing logs for
## different seeds.

import unittest2
import std/[os, algorithm]
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
  var writer = openSimTraceWriter(path, seed = seed)
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
