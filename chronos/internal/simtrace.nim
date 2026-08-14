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

proc digestOf*(trigger: SimEventId, endpoint: SimEndpointId, op: string,
               maxBytes: int, faults: openArray[string]): SimDigest =
  ## `IoOutcomePoint`'s digest: trigger, endpoint, op, maxBytes, and the
  ## sorted fault set, each already in its canonical stringification
  ## (ids per this module, `op`/`faults` by the caller - `IoOutcomePoint`
  ## itself lives in simengine.nim, outside this leaf's dependencies).
  ## The fault list joins its own elements per `canonicalJoin` first,
  ## nested inside the outer join, per 3.3's digest note.
  SimDigest(fnv1a64(canonicalJoin(
    [$trigger, $endpoint, op, $maxBytes, canonicalJoin(faults)])))

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

proc renderIoDecisionLine*(index: int, digest: SimDigest, outcome: string,
                            bytes: int, fault: string): string =
  let decision =
    if outcome == "ok": "{\"outcome\":\"ok\",\"bytes\":" & $bytes & "}"
    else: "{\"outcome\":\"fault\",\"fault\":\"" & fault & "\"}"
  "{\"i\":" & $index & ",\"kind\":\"io\",\"digest\":\"" & $digest &
    "\",\"decision\":" & decision & "}"

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

proc writeIoDecision*(writer: var SimTraceWriter, trigger: SimEventId,
                       endpoint: SimEndpointId, op: string, maxBytes: int,
                       faults: openArray[string], outcome: string,
                       bytes: int, fault: string) {.raises: [IOError].} =
  let digest = digestOf(trigger, endpoint, op, maxBytes, faults)
  writer.file.writeLine(
    renderIoDecisionLine(writer.nextIndex, digest, outcome, bytes, fault))
  writer.file.flushFile()
  inc writer.nextIndex

proc close*(writer: var SimTraceWriter) {.raises: [].} =
  writer.file.close()

# --- the ndjson reader (RFC 0003 3.7, 3.10): parses exactly the grammar the
# writer above renders. A hand-rolled scan, not a general JSON parser -
# the format is this module's own fixed schema, the same discipline the
# writer already applies to producing it.

type
  SimTraceReadError* = object of CatchableError
    ## Malformed trace text, or (3.7's version gate) a header whose
    ## `"trace"`/`"v"` fields do not match this build's
    ## `simTraceFormatName`/`simTraceVersion`.

  SimTraceHeader* = object
    seed*: uint64
    commit*: string
    config*: string

  SimTraceRecordKind* {.pure.} = enum
    Time
    Batch
    Io

  SimTraceRecord* = object
    index*: int
    digest*: SimDigest
    case kind*: SimTraceRecordKind
    of SimTraceRecordKind.Time:
      advanceToNanoseconds*: int64
    of SimTraceRecordKind.Batch:
      order*: seq[SimEventId]
    of SimTraceRecordKind.Io:
      outcome*: string
      bytes*: int
      fault*: string

proc extractStringField(line, key: string): string
                        {.raises: [SimTraceReadError].} =
  let marker = "\"" & key & "\":\""
  let start = line.find(marker)
  if start < 0:
    raise newException(SimTraceReadError,
      "missing field \"" & key & "\" in: " & line)
  let valueStart = start + marker.len
  let valueEnd = line.find('"', valueStart)
  if valueEnd < 0:
    raise newException(SimTraceReadError,
      "unterminated field \"" & key & "\" in: " & line)
  line[valueStart ..< valueEnd]

proc extractIntField(line, key: string): int64
                     {.raises: [SimTraceReadError].} =
  let marker = "\"" & key & "\":"
  let start = line.find(marker)
  if start < 0:
    raise newException(SimTraceReadError,
      "missing field \"" & key & "\" in: " & line)
  let valueStart = start + marker.len
  var valueEnd = valueStart
  while valueEnd < line.len and line[valueEnd] in {'0'..'9', '-'}:
    inc valueEnd
  let text = line[valueStart ..< valueEnd]
  if text.len == 0:
    raise newException(SimTraceReadError,
      "empty numeric field \"" & key & "\" in: " & line)
  try:
    parseBiggestInt(text)
  except ValueError:
    raise newException(SimTraceReadError,
      "malformed numeric field \"" & key & "\" in: " & line)

proc parseEventId(text: string): SimEventId {.raises: [SimTraceReadError].} =
  if text.len < 2 or text[0] != 'e':
    raise newException(SimTraceReadError, "malformed event id: " & text)
  try:
    SimEventId(uint64(parseBiggestInt(text[1 .. ^1])))
  except ValueError:
    raise newException(SimTraceReadError, "malformed event id: " & text)

proc extractEventIdList(line: string): seq[SimEventId]
                        {.raises: [SimTraceReadError].} =
  let marker = "\"order\":["
  let start = line.find(marker)
  if start < 0:
    raise newException(SimTraceReadError, "missing field \"order\" in: " & line)
  let valueStart = start + marker.len
  let valueEnd = line.find(']', valueStart)
  if valueEnd < 0:
    raise newException(SimTraceReadError,
      "unterminated field \"order\" in: " & line)
  let inner = line[valueStart ..< valueEnd]
  if inner.len == 0:
    return @[]
  for token in inner.split(','):
    result.add parseEventId(token.strip(chars = {'"'}))

proc parseHexDigest(text: string): SimDigest {.raises: [SimTraceReadError].} =
  if text.len != 16:
    raise newException(SimTraceReadError, "malformed digest: " & text)
  var value = 0'u64
  for ch in text:
    var nibble: int
    if ch in {'0'..'9'}:
      nibble = ord(ch) - ord('0')
    elif ch in {'a'..'f'}:
      nibble = ord(ch) - ord('a') + 10
    else:
      raise newException(SimTraceReadError, "malformed digest: " & text)
    value = (value shl 4) or uint64(nibble)
  SimDigest(value)

proc parseSimTraceHeader*(line: string): SimTraceHeader
                          {.raises: [SimTraceReadError].} =
  ## The version gate (3.7): refuses a header whose `"trace"`/`"v"`
  ## fields do not match this build's format name/version.
  let traceName = extractStringField(line, "trace")
  if traceName != simTraceFormatName:
    raise newException(SimTraceReadError,
      "unrecognized trace format: " & traceName)
  let version = extractIntField(line, "v")
  if version != simTraceVersion:
    raise newException(SimTraceReadError,
      "trace version mismatch: expected " & $simTraceVersion & ", got " &
      $version)
  SimTraceHeader(seed: uint64(extractIntField(line, "seed")),
                 commit: extractStringField(line, "commit"),
                 config: extractStringField(line, "config"))

proc parseSimTraceRecord*(line: string): SimTraceRecord
                          {.raises: [SimTraceReadError].} =
  let index = int(extractIntField(line, "i"))
  let digest = parseHexDigest(extractStringField(line, "digest"))
  case extractStringField(line, "kind")
  of "time":
    SimTraceRecord(index: index, digest: digest,
                    kind: SimTraceRecordKind.Time,
                    advanceToNanoseconds: extractIntField(line, "advanceTo"))
  of "batch":
    SimTraceRecord(index: index, digest: digest,
                    kind: SimTraceRecordKind.Batch,
                    order: extractEventIdList(line))
  of "io":
    let outcome = extractStringField(line, "outcome")
    if outcome == "ok":
      SimTraceRecord(index: index, digest: digest,
                      kind: SimTraceRecordKind.Io, outcome: outcome,
                      bytes: int(extractIntField(line, "bytes")), fault: "")
    else:
      SimTraceRecord(index: index, digest: digest,
                      kind: SimTraceRecordKind.Io, outcome: outcome,
                      bytes: 0, fault: extractStringField(line, "fault"))
  else:
    raise newException(SimTraceReadError,
      "unrecognized decision kind in: " & line)

proc readSimTrace*(path: string):
    tuple[header: SimTraceHeader, records: seq[SimTraceRecord]]
    {.raises: [IOError, SimTraceReadError].} =
  ## Reads and parses an entire trace file: the header line (version-
  ## gated per 3.7), then one `SimTraceRecord` per remaining non-empty
  ## line, in file order.
  let lines = readFile(path).splitLines()
  if lines.len == 0 or lines[0].len == 0:
    raise newException(SimTraceReadError, "empty trace file: " & path)
  let header = parseSimTraceHeader(lines[0])
  var records = newSeq[SimTraceRecord]()
  for line in lines[1 .. ^1]:
    if line.len == 0:
      continue
    records.add parseSimTraceRecord(line)
  (header: header, records: records)
