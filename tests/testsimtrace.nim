#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/internal/simtrace.nim`: the canonical id/digest
## stringifications (RFC 0003 3.3.1), the pinned FNV-1a `digestOf` grammar
## (3.3), and the ndjson decision-log writer (3.7).

import unittest2
import std/[os, strutils]
import ../chronos/internal/simtrace

{.used.}

suite "sim trace stringifications":
  test "SimEventId renders as e<value>":
    check $SimEventId(3'u64) == "e3"
    check $SimEventId(0'u64) == "e0"

  test "SimEndpointId renders as p<value>":
    check $SimEndpointId(7'u32) == "p7"
    check $SimEndpointId(0'u32) == "p0"

  test "SimDigest renders as fixed-width 16-digit lowercase hex":
    check $SimDigest(0'u64) == "0000000000000000"
    check $SimDigest(0xdeadbeef'u64) == "00000000deadbeef"

suite "digestOf pinned grammar":
  # Golden values computed independently via a reference FNV-1a-64
  # implementation over the exact byte strings the grammar specifies
  # (RFC 0003 3.3): canonical field stringifications joined by 0x00.
  test "digest of a single event id":
    check $digestOf(@[SimEventId(1'u64)]) == "088e7b07b539b883"

  test "digest of an ordered id list joins with 0x00":
    check $digestOf(@[SimEventId(2'u64), SimEventId(1'u64)]) ==
      "79c84bf532bd509c"

  test "digest of three ordered ids":
    check $digestOf(@[SimEventId(1'u64), SimEventId(2'u64),
                       SimEventId(3'u64)]) == "d94b4a8eefd323ce"

  test "digest order matters, not just membership":
    check $digestOf(@[SimEventId(1'u64), SimEventId(2'u64)]) !=
      $digestOf(@[SimEventId(2'u64), SimEventId(1'u64)])

  test "digest of a single armed deadline":
    check $digestOf(@[100'i64]) == "4568b718181c937c"

  test "digest of two armed deadlines joins with 0x00":
    check $digestOf(@[100'i64, 200'i64]) == "a6d89faff2f023a2"

suite "sim decision-log writer":
  test "the header line carries trace name, version, seed, commit, config":
    let path = getTempDir() / "chronos-simtrace-header.ndjson"
    var writer = openSimTraceWriter(path, seed = 12648430'u64,
                                     commit = "abc123", config = "refc")
    writer.close()
    let lines = readFile(path).splitLines()
    check lines[0] ==
      "{\"trace\":\"chronos-sim\",\"v\":1,\"seed\":12648430," &
      "\"commit\":\"abc123\",\"config\":\"refc\"}"
    removeFile(path)

  test "a time decision line carries its index, digest, and advanceTo":
    let path = getTempDir() / "chronos-simtrace-time.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    writer.writeTimeDecision(@[100'i64], 100'i64)
    writer.close()
    let lines = readFile(path).splitLines()
    check lines[1] ==
      "{\"i\":0,\"kind\":\"time\",\"digest\":\"" & $digestOf(@[100'i64]) &
      "\",\"decision\":{\"advanceTo\":100}}"
    removeFile(path)

  test "a batch decision line carries its index, digest, and order":
    let path = getTempDir() / "chronos-simtrace-batch.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    let deliverable = @[SimEventId(1'u64), SimEventId(2'u64)]
    let order = @[SimEventId(2'u64), SimEventId(1'u64)]
    writer.writeBatchDecision(deliverable, order)
    writer.close()
    let lines = readFile(path).splitLines()
    check lines[1] ==
      "{\"i\":0,\"kind\":\"batch\",\"digest\":\"" & $digestOf(deliverable) &
      "\",\"decision\":{\"order\":[\"e2\",\"e1\"]}}"
    removeFile(path)

  test "the decision index increments across writes":
    let path = getTempDir() / "chronos-simtrace-index.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    writer.writeTimeDecision(@[100'i64], 100'i64)
    writer.writeBatchDecision(@[SimEventId(1'u64)], @[SimEventId(1'u64)])
    writer.close()
    let lines = readFile(path).splitLines()
    check "\"i\":0" in lines[1]
    check "\"i\":1" in lines[2]
    removeFile(path)
