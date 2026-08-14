#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## The deterministic simulation substrate's trace schema (RFC 0003 3.3.1,
## 3.7, 3.10): the canonical stringifications every simulated entity id
## renders through, `SimDigest` and the pinned FNV-1a choice-point digest,
## and the ndjson decision-log writer.
##
## Leaf module: no dispatcher imports. This is what a future conformance
## checker (issue #16) can import on its own, without pulling in
## `chronos/internal/simengine.nim` or the dispatcher it instruments -
## `simengine.nim` imports this module, and this module never imports it
## back.

{.push raises: [], gcsafe.}

import std/strutils

type
  SimEventId* = distinct uint64
    ## Monotonic per-run counter (RFC 0003 3.3.1): every `SimEvent`, a
    ## `Readiness` completion or an `Arrival` batch alike, gets its id
    ## from one counter owned by the simulation state, so ids sort into
    ## a single total order regardless of which choice point produced
    ## them.

  SimEndpointId* = distinct uint32
    ## The id of a `SimEvent`'s source: a sim-minted fd, an arrival
    ## actor, or (a future slice's) transport endpoint.

  SimDigest* = distinct uint64
    ## The pinned choice-point digest (RFC 0003 3.3): 64-bit FNV-1a over
    ## the canonical text serialization of a choice point's payload.
    ## Renders as fixed-width 16-digit lowercase hex, the same
    ## discipline 3.3.1 applies to entity ids.

const
  simTraceFormatName* = "chronos-sim"
    ## The ndjson header's `"trace"` field (RFC 0003 3.7).
  simTraceVersion* = 1
    ## The ndjson header's `"v"` field. A version bump changes required
    ## keys only; a replay oracle refuses a mismatched version.

  fnvOffsetBasis64 = 0xcbf29ce484222325'u64
  fnvPrime64 = 0x100000001b3'u64

proc `==`*(a, b: SimEventId): bool {.borrow.}
proc `<`*(a, b: SimEventId): bool {.borrow.}
proc `$`*(id: SimEventId): string =
  "e" & $uint64(id)

proc `==`*(a, b: SimEndpointId): bool {.borrow.}
proc `$`*(id: SimEndpointId): string =
  "p" & $uint32(id)

proc `==`*(a, b: SimDigest): bool {.borrow.}
proc `$`*(digest: SimDigest): string =
  toHex(uint64(digest)).toLowerAscii()

proc fnv1a64(data: string): uint64 =
  result = fnvOffsetBasis64
  for ch in data:
    result = result xor uint64(ord(ch))
    result = result * fnvPrime64

proc canonicalJoin(fields: openArray[string]): string =
  ## The grammar's join step (RFC 0003 3.3's digest note): field values
  ## in declared order, joined by a single 0x00 byte. 0x00 never occurs
  ## inside a rendered field (every field here is a decimal integer or
  ## an id's canonical stringification), which makes the join
  ## injective.
  for i, field in fields:
    if i > 0:
      result.add '\x00'
    result.add field

proc digestOf*(orderedIds: openArray[SimEventId]): SimDigest =
  ## `SelectBatchPoint`'s digest: the ordered id list, each id in its
  ## canonical stringification, joined per `canonicalJoin`.
  var fields = newSeq[string](orderedIds.len)
  for i, id in orderedIds:
    fields[i] = $id
  SimDigest(fnv1a64(canonicalJoin(fields)))

proc digestOf*(armedNanoseconds: openArray[int64]): SimDigest =
  ## `TimeAdvancePoint`'s digest: the armed deadlines as decimal
  ## nanoseconds, joined per `canonicalJoin`.
  var fields = newSeq[string](armedNanoseconds.len)
  for i, ns in armedNanoseconds:
    fields[i] = $ns
  SimDigest(fnv1a64(canonicalJoin(fields)))

proc renderHeaderLine*(seed: uint64, commit, config: string): string =
  "{\"trace\":\"" & simTraceFormatName & "\",\"v\":" & $simTraceVersion &
    ",\"seed\":" & $seed & ",\"commit\":\"" & commit & "\",\"config\":\"" &
    config & "\"}"

proc renderTimeDecisionLine*(index: int, digest: SimDigest,
                              advanceToNanoseconds: int64): string =
  "{\"i\":" & $index & ",\"kind\":\"time\",\"digest\":\"" & $digest &
    "\",\"decision\":{\"advanceTo\":" & $advanceToNanoseconds & "}}"

proc renderBatchDecisionLine*(index: int, digest: SimDigest,
                               order: openArray[SimEventId]): string =
  var ids = "["
  for i, id in order:
    if i > 0:
      ids.add ','
    ids.add '"'
    ids.add $id
    ids.add '"'
  ids.add ']'
  "{\"i\":" & $index & ",\"kind\":\"batch\",\"digest\":\"" & $digest &
    "\",\"decision\":{\"order\":" & ids & "}}"

type
  SimTraceWriter* = object
    ## An append-only ndjson decision log (RFC 0003 3.7): one header
    ## line at construction, one decision line per `writeXDecision`
    ## call, flushed after every line so a crash mid-run loses nothing
    ## already written.
    file: File
    nextIndex: int

proc openSimTraceWriter*(path: string, seed: uint64, commit = "",
                          config = ""): SimTraceWriter
                         {.raises: [IOError].} =
  let file = open(path, fmWrite)
  file.writeLine(renderHeaderLine(seed, commit, config))
  file.flushFile()
  SimTraceWriter(file: file, nextIndex: 0)

proc writeTimeDecision*(writer: var SimTraceWriter,
                         armedNanoseconds: openArray[int64],
                         advanceToNanoseconds: int64) {.raises: [IOError].} =
  let digest = digestOf(armedNanoseconds)
  writer.file.writeLine(
    renderTimeDecisionLine(writer.nextIndex, digest, advanceToNanoseconds))
  writer.file.flushFile()
  inc writer.nextIndex

proc writeBatchDecision*(writer: var SimTraceWriter,
                          deliverableIds: openArray[SimEventId],
                          order: openArray[SimEventId])
                         {.raises: [IOError].} =
  let digest = digestOf(deliverableIds)
  writer.file.writeLine(
    renderBatchDecisionLine(writer.nextIndex, digest, order))
  writer.file.flushFile()
  inc writer.nextIndex

proc close*(writer: var SimTraceWriter) {.raises: [].} =
  writer.file.close()
