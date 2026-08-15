#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for the datagram I/O seam's sim half (RFC 0003 6, slice S12a):
## `chronos/internal/simengine.nim`'s `simDatagramIo` and
## `chronos/internal/asyncengine.nim`'s dispatcher-level `simDatagramIo`
## wrapper - the exact call `chronos/transports/datagram.nim`'s
## POSIX-only `rawIoRecvfrom`/`rawIoSendto` make through their private
## `simRawIo` forwarder once `isSimDispatcher()` is true.
##
## S12a is seam extraction only (RFC 0003 6): no `SimNet` datagram
## endpoint exists yet to mint a sim-native `DatagramTransport` through
## (S12b's scope). Unlike `stream.nim`'s `TransportKind.Pipe`/
## `fromPipe`, `chronos/transports/datagram.nim` has no syscall-free way
## to wrap a bare sim-minted fd in a real `DatagramTransport` - every
## constructor there reaches a real `bind()` unconditionally. This probe
## therefore drives `decideIo` through the seam's dispatcher-level entry
## point directly, "without a full transport" (the phrase
## `testsimstream.nim`'s own docstring uses for its bare-fd probes) -
## proving the scripted oracle is reached with the right
## op/maxBytes/endpoint id, and that both `IoDecision` outcomes
## (`Ok`/`Fault`) translate to the `(res, err)` shape
## `chronos/transports/datagram.nim`'s callers already branch on.

{.used.}

when defined(chronosSimulation) and compileOption("threads"):
  import unittest2
  import results
  import ../chronos
  import ../chronos/oserrno
  import ../chronos/internal/simengine

  type
    ProbeOutcome = object
      ok: bool
      msg: string

  var probeChan: Channel[ProbeOutcome]
  probeChan.open()

  template runProbe(threadProc: typed): ProbeOutcome =
    var probeThread: Thread[void]
    createThread(probeThread, threadProc)
    let outcome = probeChan.recv()
    joinThread(probeThread)
    outcome

  proc probeDatagramWriteRoutesThroughDecideIo() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    var calls = 0
    var seenOp = SimIoOp.Read
    var seenMaxBytes = -1
    var seenEndpoint = SimEndpointId(0'u32)

    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      inc calls
      seenOp = cp.op
      seenMaxBytes = cp.maxBytes
      seenEndpoint = cp.endpoint
      ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: cp.maxBytes))

    let oracle = newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)
    let disp = newSimDispatcher(oracle = oracle)
    setThreadDispatcher(disp)
    let fd = disp.mintSimFd()

    var payload = @[1'u8, 2, 3, 4, 5]
    let (res, err) = disp.simDatagramIo(fd, SimIoOp.Write, addr payload[0],
                                         payload.len)

    if calls != 1:
      outcome = ProbeOutcome(ok: false,
        msg: "decideIo called " & $calls & " times, expected 1")
    elif seenOp != SimIoOp.Write:
      outcome = ProbeOutcome(ok: false,
        msg: "decideIo saw op " & $seenOp & ", expected Write")
    elif seenMaxBytes != 5:
      outcome = ProbeOutcome(ok: false,
        msg: "decideIo saw maxBytes " & $seenMaxBytes & ", expected 5")
    elif seenEndpoint != SimEndpointId(uint32(fd)):
      outcome = ProbeOutcome(ok: false,
        msg: "decideIo saw the wrong endpoint id")
    elif res != 5:
      outcome = ProbeOutcome(ok: false,
        msg: "simDatagramIo returned " & $res & " bytes, expected 5")
    elif err != OSErrorCode(0):
      outcome = ProbeOutcome(ok: false,
        msg: "simDatagramIo returned a nonzero error alongside a byte count")
    probeChan.send(outcome)

  proc probeDatagramFaultTranslates() {.thread.} =
    var outcome = ProbeOutcome(ok: true)

    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Reset))

    let oracle = newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)
    let disp = newSimDispatcher(oracle = oracle)
    setThreadDispatcher(disp)
    let fd = disp.mintSimFd()

    var buf = newSeq[byte](16)
    let (res, err) = disp.simDatagramIo(fd, SimIoOp.Read, addr buf[0], 16)

    if res != -1:
      outcome = ProbeOutcome(ok: false,
        msg: "simDatagramIo returned " & $res & " on a fault, expected -1")
    elif err != simFaultToError(SimFault.Reset):
      outcome = ProbeOutcome(ok: false,
        msg: "simDatagramIo's fault did not translate to the real " &
          "error-classification logic's expected OSErrorCode")
    probeChan.send(outcome)

  suite "sim datagram I/O seam":
    test "a write routes through decideIo with the right op/maxBytes/endpoint":
      let outcome = runProbe(probeDatagramWriteRoutesThroughDecideIo)
      checkpoint outcome.msg
      check outcome.ok

    test "a Fault outcome translates to the real error-classification OSErrorCode":
      let outcome = runProbe(probeDatagramFaultTranslates)
      checkpoint outcome.msg
      check outcome.ok
