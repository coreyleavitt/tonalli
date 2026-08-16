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

  test "digest of an io outcome point with no faults":
    check $digestOf(SimEventId(1'u64), SimEndpointId(2'u32), "read", 64,
                     newSeq[string]()) == "7797b815e66df923"

  test "digest of an io outcome point changes with maxBytes":
    check $digestOf(SimEventId(1'u64), SimEndpointId(2'u32), "read", 128,
                     newSeq[string]()) == "eb74721e31240cc4"

  test "digest of an io outcome point with a fault":
    check $digestOf(SimEventId(1'u64), SimEndpointId(2'u32), "write", 64,
                     @["reset"]) == "224e66f4bb617941"

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

  test "an io decision line with an Ok outcome carries its bytes":
    let path = getTempDir() / "chronos-simtrace-io-ok.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    writer.writeIoDecision(SimEventId(1'u64), SimEndpointId(2'u32), "read",
                            64, newSeq[string](), "ok", 64, "")
    writer.close()
    let lines = readFile(path).splitLines()
    let digest = digestOf(SimEventId(1'u64), SimEndpointId(2'u32), "read",
                           64, newSeq[string]())
    check lines[1] ==
      "{\"i\":0,\"kind\":\"io\",\"digest\":\"" & $digest &
      "\",\"decision\":{\"outcome\":\"ok\",\"bytes\":64}}"
    removeFile(path)

  test "an io decision line with a Fault outcome carries its fault":
    let path = getTempDir() / "chronos-simtrace-io-fault.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    writer.writeIoDecision(SimEventId(1'u64), SimEndpointId(2'u32), "write",
                            64, @["reset"], "fault", 0, "reset")
    writer.close()
    let lines = readFile(path).splitLines()
    let digest = digestOf(SimEventId(1'u64), SimEndpointId(2'u32), "write",
                           64, @["reset"])
    check lines[1] ==
      "{\"i\":0,\"kind\":\"io\",\"digest\":\"" & $digest &
      "\",\"decision\":{\"outcome\":\"fault\",\"fault\":\"reset\"}}"
    removeFile(path)

suite "sim trace reader":
  test "reads back the header a writer wrote":
    let path = getTempDir() / "chronos-simtrace-read-header.ndjson"
    var writer = openSimTraceWriter(path, seed = 12648430'u64,
                                     commit = "abc123", config = "refc")
    writer.close()
    let trace = readSimTrace(path)
    check trace.header.seed == 12648430'u64
    check trace.header.commit == "abc123"
    check trace.header.config == "refc"
    check trace.records.len == 0
    removeFile(path)

  test "reads back a time decision":
    let path = getTempDir() / "chronos-simtrace-read-time.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    writer.writeTimeDecision(@[100'i64, 200'i64], 150'i64)
    writer.close()
    let trace = readSimTrace(path)
    check trace.records.len == 1
    check trace.records[0].index == 0
    check trace.records[0].kind == SimTraceRecordKind.Time
    check trace.records[0].digest == digestOf(@[100'i64, 200'i64])
    check trace.records[0].advanceToNanoseconds == 150'i64
    removeFile(path)

  test "reads back a batch decision":
    let path = getTempDir() / "chronos-simtrace-read-batch.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    let deliverable = @[SimEventId(1'u64), SimEventId(2'u64)]
    let order = @[SimEventId(2'u64), SimEventId(1'u64)]
    writer.writeBatchDecision(deliverable, order)
    writer.close()
    let trace = readSimTrace(path)
    check trace.records.len == 1
    check trace.records[0].kind == SimTraceRecordKind.Batch
    check trace.records[0].digest == digestOf(deliverable)
    check trace.records[0].order == order
    removeFile(path)

  test "reads back an io decision with an Ok outcome":
    let path = getTempDir() / "chronos-simtrace-read-io-ok.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    writer.writeIoDecision(SimEventId(1'u64), SimEndpointId(2'u32), "read",
                            64, newSeq[string](), "ok", 64, "")
    writer.close()
    let trace = readSimTrace(path)
    check trace.records.len == 1
    check trace.records[0].kind == SimTraceRecordKind.Io
    check trace.records[0].digest ==
      digestOf(SimEventId(1'u64), SimEndpointId(2'u32), "read", 64,
               newSeq[string]())
    check trace.records[0].outcome == "ok"
    check trace.records[0].bytes == 64

  test "reads back an io decision with a Fault outcome":
    let path = getTempDir() / "chronos-simtrace-read-io-fault.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    writer.writeIoDecision(SimEventId(1'u64), SimEndpointId(2'u32), "write",
                            64, @["reset"], "fault", 0, "reset")
    writer.close()
    let trace = readSimTrace(path)
    check trace.records[0].outcome == "fault"
    check trace.records[0].fault == "reset"
    removeFile(path)

  test "the decision index round-trips across multiple records":
    let path = getTempDir() / "chronos-simtrace-read-index.ndjson"
    var writer = openSimTraceWriter(path, seed = 1'u64)
    writer.writeTimeDecision(@[100'i64], 100'i64)
    writer.writeBatchDecision(@[SimEventId(1'u64)], @[SimEventId(1'u64)])
    writer.close()
    let trace = readSimTrace(path)
    check trace.records[0].index == 0
    check trace.records[1].index == 1
    removeFile(path)

  test "a mismatched trace version is refused":
    let path = getTempDir() / "chronos-simtrace-read-badversion.ndjson"
    writeFile(path,
      "{\"trace\":\"chronos-sim\",\"v\":99,\"seed\":1,\"commit\":\"\"," &
      "\"config\":\"\"}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "a mismatched trace format name is refused":
    let path = getTempDir() / "chronos-simtrace-read-badformat.ndjson"
    writeFile(path,
      "{\"trace\":\"not-chronos-sim\",\"v\":1,\"seed\":1,\"commit\":\"\"," &
      "\"config\":\"\"}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  const validHeaderLine =
    "{\"trace\":\"chronos-sim\",\"v\":1,\"seed\":1,\"commit\":\"\"," &
    "\"config\":\"\"}\n"

  test "an empty trace file is refused":
    let path = getTempDir() / "chronos-simtrace-read-empty.ndjson"
    writeFile(path, "")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "a record missing a required field is refused":
    let path = getTempDir() / "chronos-simtrace-read-missingfield.ndjson"
    writeFile(path, validHeaderLine &
      "{\"i\":0,\"kind\":\"time\",\"decision\":{\"advanceTo\":100}}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "an unterminated string field in the header is refused":
    let path = getTempDir() / "chronos-simtrace-read-unterminated.ndjson"
    writeFile(path,
      "{\"trace\":\"chronos-sim\",\"v\":1,\"seed\":1,\"commit\":\"abc\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "a digest of the wrong length is refused":
    let path = getTempDir() / "chronos-simtrace-read-digestlen.ndjson"
    writeFile(path, validHeaderLine &
      "{\"i\":0,\"kind\":\"time\",\"digest\":\"deadbeef\"," &
      "\"decision\":{\"advanceTo\":100}}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "a digest with non-hex characters is refused":
    let path = getTempDir() / "chronos-simtrace-read-digesthex.ndjson"
    writeFile(path, validHeaderLine &
      "{\"i\":0,\"kind\":\"time\",\"digest\":\"deadbeefdeadbeeg\"," &
      "\"decision\":{\"advanceTo\":100}}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "a non-numeric event id is refused":
    let path = getTempDir() / "chronos-simtrace-read-badeventid.ndjson"
    writeFile(path, validHeaderLine &
      "{\"i\":0,\"kind\":\"batch\",\"digest\":\"0000000000000000\"," &
      "\"decision\":{\"order\":[\"exyz\"]}}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "a negative event id is refused":
    let path = getTempDir() / "chronos-simtrace-read-negeventid.ndjson"
    writeFile(path, validHeaderLine &
      "{\"i\":0,\"kind\":\"batch\",\"digest\":\"0000000000000000\"," &
      "\"decision\":{\"order\":[\"e-5\"]}}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "a full-range uint64 seed round-trips through the header":
    let header = parseSimTraceHeader(
      renderHeaderLine(high(uint64), "abc", "cfg"))
    check header.seed == high(uint64)

  test "a negative seed is refused":
    expect SimTraceReadError:
      discard parseSimTraceHeader(
        "{\"trace\":\"chronos-sim\",\"v\":1,\"seed\":-5,\"commit\":\"\"," &
        "\"config\":\"\"}")

  test "an unrecognized decision kind is refused":
    let path = getTempDir() / "chronos-simtrace-read-badkind.ndjson"
    writeFile(path, validHeaderLine &
      "{\"i\":0,\"kind\":\"bogus\",\"digest\":\"0000000000000000\"," &
      "\"decision\":{}}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "an out-of-range decision index is refused":
    let path = getTempDir() / "chronos-simtrace-read-bigindex.ndjson"
    writeFile(path, validHeaderLine &
      "{\"i\":99999999999,\"kind\":\"time\",\"digest\":\"0000000000000000\"," &
      "\"decision\":{\"advanceTo\":100}}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)

  test "an out-of-range io byte count is refused":
    let path = getTempDir() / "chronos-simtrace-read-bigbytes.ndjson"
    writeFile(path, validHeaderLine &
      "{\"i\":0,\"kind\":\"io\",\"digest\":\"0000000000000000\"," &
      "\"decision\":{\"outcome\":\"ok\",\"bytes\":99999999999}}\n")
    expect SimTraceReadError:
      discard readSimTrace(path)
    removeFile(path)
