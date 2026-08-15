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
    let (res, err, _) = disp.simDatagramIo(fd, SimIoOp.Write, addr payload[0],
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
    let (res, err, _) = disp.simDatagramIo(fd, SimIoOp.Read, addr buf[0], 16)

    if res != -1:
      outcome = ProbeOutcome(ok: false,
        msg: "simDatagramIo returned " & $res & " on a fault, expected -1")
    elif err != simFaultToError(SimFault.Reset):
      outcome = ProbeOutcome(ok: false,
        msg: "simDatagramIo's fault did not translate to the real " &
          "error-classification logic's expected OSErrorCode")
    probeChan.send(outcome)

  proc probeDatagramPairRoundTripCarriesPeerAddress() {.thread.} =
    ## S12b's first slice (RFC 0003 6): `mintSimDatagramPair` wires two
    ## sim fds as fixed peers, each carrying its own address; a write on
    ## one side queues a whole datagram on the other's endpoint, and the
    ## matching read reports the sender's address back through the
    ## `fromAddr` seam - the datagram-native counterpart to S11a's
    ## `simMintStreamPair` (which has no peer-address concept at all,
    ## since a stream's peer is fixed once at connect time, not carried
    ## per read).
    var outcome = ProbeOutcome(ok: true)
    let disp = newSimDispatcher()
    setThreadDispatcher(disp)

    let addrA = @[1'u8, 2, 3, 4]
    let addrB = @[9'u8, 8, 7, 6, 5]
    let (fdA, fdB) = disp.simMintDatagramPair(addrA, addrB)

    var sent = @[10'u8, 20, 30]
    let wres = disp.simDatagramIo(fdA, SimIoOp.Write, addr sent[0], sent.len)
    if wres.res != 3 or wres.err != OSErrorCode(0):
      outcome = ProbeOutcome(ok: false,
        msg: "write returned " & $wres.res & "/" & $int(wres.err) &
          ", expected 3/0")
    else:
      var buf = newSeq[byte](16)
      let rres = disp.simDatagramIo(fdB, SimIoOp.Read, addr buf[0], buf.len)
      if rres.res != 3 or rres.err != OSErrorCode(0):
        outcome = ProbeOutcome(ok: false,
          msg: "read returned " & $rres.res & "/" & $int(rres.err) &
            ", expected 3/0")
      elif buf[0 ..< 3] != sent:
        outcome = ProbeOutcome(ok: false,
          msg: "read payload " & $buf[0 ..< 3] & " != written payload " & $sent)
      elif rres.fromAddr != addrA:
        outcome = ProbeOutcome(ok: false,
          msg: "read fromAddr " & $rres.fromAddr &
            " != sender's own address " & $addrA)
    probeChan.send(outcome)

  proc probeDatagramReadWithNothingQueuedWouldBlock() {.thread.} =
    ## No content and no fault path exists yet at mint time (mirroring
    ## `simStreamIo`'s "structural fact, not a choice" rule for an empty
    ## queue): a read against a freshly-minted, still-empty endpoint
    ## answers EWOULDBLOCK without ever reaching the oracle.
    var outcome = ProbeOutcome(ok: true)
    var calls = 0
    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      inc calls
      defaultDecideIo(cp)
    let oracle = newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)
    let disp = newSimDispatcher(oracle = oracle)
    setThreadDispatcher(disp)
    let (fdA, fdB) = disp.simMintDatagramPair(@[1'u8], @[2'u8])
    discard fdA
    var buf = newSeq[byte](16)
    let rres = disp.simDatagramIo(fdB, SimIoOp.Read, addr buf[0], buf.len)
    when defined(windows):
      let expectedErr = oserrno.WSAEWOULDBLOCK
    else:
      let expectedErr = oserrno.EWOULDBLOCK
    if rres.res != -1 or rres.err != expectedErr:
      outcome = ProbeOutcome(ok: false,
        msg: "empty-queue read returned " & $rres.res & "/" & $int(rres.err) &
          ", expected -1/" & $int(expectedErr))
    elif calls != 0:
      outcome = ProbeOutcome(ok: false,
        msg: "empty-queue read consulted decideIo " & $calls &
          " times, expected 0 (structural would-block, not a choice)")
    probeChan.send(outcome)

  proc probeDatagramDropFaultVanishesSilently() {.thread.} =
    ## Drop is a write-side choice (RFC 0003 6, S12b's placement
    ## rationale): the sender's local call still succeeds (real UDP
    ## never fails a send over packet loss), but the datagram never
    ## reaches the peer's queue.
    var outcome = ProbeOutcome(ok: true)
    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      if cp.op == SimIoOp.Write:
        ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Drop))
      else:
        defaultDecideIo(cp)
    let oracle = newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)
    let disp = newSimDispatcher(oracle = oracle)
    setThreadDispatcher(disp)
    let (fdA, fdB) = disp.simMintDatagramPair(@[1'u8], @[2'u8])

    var sent = @[1'u8, 2, 3]
    let wres = disp.simDatagramIo(fdA, SimIoOp.Write, addr sent[0], sent.len)
    if wres.res != 3 or wres.err != OSErrorCode(0):
      outcome = ProbeOutcome(ok: false,
        msg: "dropped write returned " & $wres.res & "/" & $int(wres.err) &
          ", expected the sender to see success (3/0) despite the drop")
    else:
      var buf = newSeq[byte](16)
      let rres = disp.simDatagramIo(fdB, SimIoOp.Read, addr buf[0], buf.len)
      when defined(windows):
        let expectedErr = oserrno.WSAEWOULDBLOCK
      else:
        let expectedErr = oserrno.EWOULDBLOCK
      if rres.res != -1 or rres.err != expectedErr:
        outcome = ProbeOutcome(ok: false,
          msg: "peer read after a dropped write returned " & $rres.res &
            "/" & $int(rres.err) & ", expected it to have never arrived " &
            "(-1/" & $int(expectedErr) & ")")
    probeChan.send(outcome)

  proc probeDatagramDuplicateFaultDeliversTwice() {.thread.} =
    ## Duplicate is a write-side choice, same placement as Drop: one
    ## sender call, two whole datagrams queued on the peer.
    var outcome = ProbeOutcome(ok: true)
    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      if cp.op == SimIoOp.Write:
        ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Duplicate))
      else:
        defaultDecideIo(cp)
    let oracle = newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)
    let disp = newSimDispatcher(oracle = oracle)
    setThreadDispatcher(disp)
    let (fdA, fdB) = disp.simMintDatagramPair(@[1'u8], @[2'u8])

    var sent = @[7'u8, 8, 9]
    discard disp.simDatagramIo(fdA, SimIoOp.Write, addr sent[0], sent.len)

    var buf1 = newSeq[byte](16)
    let r1 = disp.simDatagramIo(fdB, SimIoOp.Read, addr buf1[0], buf1.len)
    var buf2 = newSeq[byte](16)
    let r2 = disp.simDatagramIo(fdB, SimIoOp.Read, addr buf2[0], buf2.len)
    if r1.res != 3 or buf1[0 ..< 3] != sent:
      outcome = ProbeOutcome(ok: false,
        msg: "first read after a duplicated write: " & $r1.res & " bytes, " &
          $buf1[0 ..< 3] & ", expected 3 bytes " & $sent)
    elif r2.res != 3 or buf2[0 ..< 3] != sent:
      outcome = ProbeOutcome(ok: false,
        msg: "second read after a duplicated write: " & $r2.res &
          " bytes, " & $buf2[0 ..< 3] & ", expected the same datagram " &
          "delivered twice (3 bytes " & $sent & ")")
    probeChan.send(outcome)

  proc probeDatagramReorderFaultDeliversOutOfOrder() {.thread.} =
    ## Reorder is a write-side choice, same placement as Drop/Duplicate:
    ## the second of two sent datagrams is scripted to reorder ahead of
    ## the first, which is still queued and unread at the time it sends
    ## - `simDatagramDeliver`'s documented reorder rule (insert at the
    ## front of the peer's queue instead of the back).
    var outcome = ProbeOutcome(ok: true)
    var writeCount = 0
    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      if cp.op == SimIoOp.Write:
        inc writeCount
        if writeCount == 2:
          return ok(IoDecision(outcome: SimIoOutcome.Fault,
                                fault: SimFault.Reorder))
      defaultDecideIo(cp)
    let oracle = newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)
    let disp = newSimDispatcher(oracle = oracle)
    setThreadDispatcher(disp)
    let (fdA, fdB) = disp.simMintDatagramPair(@[1'u8], @[2'u8])

    var first = @[1'u8]
    var second = @[2'u8]
    discard disp.simDatagramIo(fdA, SimIoOp.Write, addr first[0], first.len)
    discard disp.simDatagramIo(fdA, SimIoOp.Write, addr second[0], second.len)

    var buf1 = newSeq[byte](4)
    let r1 = disp.simDatagramIo(fdB, SimIoOp.Read, addr buf1[0], buf1.len)
    var buf2 = newSeq[byte](4)
    let r2 = disp.simDatagramIo(fdB, SimIoOp.Read, addr buf2[0], buf2.len)
    if r1.res != 1 or buf1[0] != 2'u8:
      outcome = ProbeOutcome(ok: false,
        msg: "first delivered datagram was " & $buf1[0 ..< r1.res] &
          ", expected the reordered second send ([2]) to arrive first")
    elif r2.res != 1 or buf2[0] != 1'u8:
      outcome = ProbeOutcome(ok: false,
        msg: "second delivered datagram was " & $buf2[0 ..< r2.res] &
          ", expected the first send ([1]) to arrive after it")
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

  suite "sim datagram endpoints":
    test "a write on one side of a minted pair is read whole on the other, with the sender's address":
      let outcome = runProbe(probeDatagramPairRoundTripCarriesPeerAddress)
      checkpoint outcome.msg
      check outcome.ok

    test "a read against an empty endpoint would-block without consulting the oracle":
      let outcome = runProbe(probeDatagramReadWithNothingQueuedWouldBlock)
      checkpoint outcome.msg
      check outcome.ok

    test "drop fault: the sender sees success but the datagram never arrives":
      let outcome = runProbe(probeDatagramDropFaultVanishesSilently)
      checkpoint outcome.msg
      check outcome.ok

    test "duplicate fault: one send is delivered twice":
      let outcome = runProbe(probeDatagramDuplicateFaultDeliversTwice)
      checkpoint outcome.msg
      check outcome.ok

    test "reorder fault: the second send arrives before the first":
      let outcome = runProbe(probeDatagramReorderFaultDeliversOutOfOrder)
      checkpoint outcome.msg
      check outcome.ok

  ## The accessor and fixture tests below build real `DatagramTransport`s
  ## through `chronos/simulation.nim`'s `SimNet.datagramPair` (RFC 0003
  ## 6, S12b), which sits on `chronos/transports/datagram.nim`'s POSIX-
  ## only `simDatagramPair` - the datagram I/O seam itself is POSIX-only
  ## (S12a, mirroring S10's Windows IOCP-emulation non-goal), so these
  ## are POSIX-only in execution the same way `testsimnet.nim`'s stream
  ## accessor tests already are. The dispatcher-level probes above stay
  ## platform-neutral, since they call the engine wrapper directly and
  ## never reach `datagram.nim`'s POSIX-only branch.
  when not defined(windows):
    import ../chronos/simulation

    proc bytesToStr(b: seq[byte]): string =
      result = newString(b.len)
      if b.len > 0:
        copyMem(addr result[0], unsafeAddr b[0], b.len)

    proc probeDatagramPairEchoUnderSim() {.thread.} =
      ## The accessor's baseline, testdatagram-shaped fixture (RFC 0003
      ## 6, S12b): a REQUEST/ANSWER round trip over a `datagramPair`,
      ## no fault injected - the shape every fault test below starts
      ## from.
      var outcome = ProbeOutcome(ok: true)
      setThreadDispatcher(newSimDispatcher())

      proc body() {.async: (raises: [TransportError, CancelledError]).} =
        let net = simNet()
        var responseFut = Future[string].Raising([CancelledError]).init(
          "datagram.echo.response")

        proc serverCb(transp: DatagramTransport, raddr: TransportAddress):
            Future[void] {.async: (raises: []).} =
          try:
            discard transp.getMessage()
            await transp.sendTo(raddr, "ANSWER")
          except CatchableError as exc:
            raiseAssert exc.msg

        proc clientCb(transp: DatagramTransport, raddr: TransportAddress):
            Future[void] {.async: (raises: []).} =
          try:
            let data = transp.getMessage()
            if not responseFut.finished():
              responseFut.complete(bytesToStr(data))
          except CatchableError as exc:
            raiseAssert exc.msg

        let (client, server) = net.datagramPair(
          initTAddress("127.0.0.1:0"), initTAddress("127.0.0.1:0"),
          clientCb, serverCb)
        await client.send("REQUEST")
        let response = await responseFut
        if response != "ANSWER":
          outcome = ProbeOutcome(ok: false,
            msg: "echo mismatch: got " & response & ", expected ANSWER")
        await client.closeWait()
        await server.closeWait()

      try:
        waitFor body()
      except CatchableError as exc:
        outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
      probeChan.send(outcome)

    proc resetOnEndpointRead(faulted: SimEndpointId): SimOracle =
      ## Reset is a recv-side choice (RFC 0003 6, S12b's placement
      ## rationale, `simDatagramIo`'s own docstring): this scripts it
      ## onto exactly one endpoint's reads, leaving the other endpoint -
      ## and every write - answered by the default rule, the same
      ## `chunkedIoOracle`-style scoped-override shape
      ## `testsimnet.nim`'s S11b probes already use.
      proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
          {.gcsafe, raises: [].} =
        if cp.op == SimIoOp.Read and cp.endpoint == faulted:
          ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Reset))
        else:
          defaultDecideIo(cp)
      newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)

    proc probeDatagramResetFaultProbe(naive: bool): ProbeOutcome =
      ## Shared body for both the RED (`naive = true`) and GREEN
      ## (`naive = false`) halves of the reset cycle (RFC 0003 6,
      ## S12b): a reset fault lands on the *client's* read of the
      ## server's echo (`SimEndpointId(0)`, the first endpoint
      ## `datagramPair` mints in a fresh dispatcher, deterministic and
      ## reproducible for the same construction order every run - no
      ## other fd is minted first in this probe). The naive client
      ## callback mirrors `tests/testdatagram.nim`'s real production
      ## `client1`/`client2` shape (a read error is caught only enough
      ## to satisfy `DatagramCallback`'s `raises: []`, then silently
      ## dropped) - a bug the real, non-sim suite has never been able
      ## to exercise, since triggering `ECONNRESET` on a real UDP
      ## socket deterministically is impractical outside of fault
      ## injection. Dropped silently, `responseFut` never completes;
      ## `simulate()`'s S3 quiescence detector (already-existing
      ## infrastructure, unmodified here) catches the resulting deadlock
      ## immediately - no wall-clock hang.
      var outcome = ProbeOutcome(ok: true)
      setThreadDispatcher(
        newSimDispatcher(oracle = resetOnEndpointRead(SimEndpointId(0))))

      proc body() {.async: (raises: [TransportError, CancelledError]).} =
        let net = simNet()
        var responseFut = Future[string].Raising([CancelledError]).init(
          "datagram.reset.response")

        proc serverCb(transp: DatagramTransport, raddr: TransportAddress):
            Future[void] {.async: (raises: []).} =
          try:
            discard transp.getMessage()
            await transp.sendTo(raddr, "ANSWER")
          except CatchableError as exc:
            raiseAssert exc.msg

        proc clientCb(transp: DatagramTransport, raddr: TransportAddress):
            Future[void] {.async: (raises: []).} =
          try:
            let data = transp.getMessage()
            if not responseFut.finished():
              responseFut.complete(bytesToStr(data))
          except TransportError:
            if not naive:
              if not responseFut.finished():
                responseFut.fail(newException(CancelledError,
                  "read reset while awaiting the echo"))
          except CatchableError as exc:
            raiseAssert exc.msg

        let (client, server) = net.datagramPair(
          initTAddress("127.0.0.1:0"), initTAddress("127.0.0.1:0"),
          clientCb, serverCb)
        await client.send("REQUEST")
        try:
          discard await responseFut
          if naive:
            outcome = ProbeOutcome(ok: false,
              msg: "naive fixture unexpectedly received a response despite " &
                "the injected reset")
        except CancelledError:
          if naive:
            outcome = ProbeOutcome(ok: false,
              msg: "naive fixture unexpectedly observed the reset cleanly")
        await client.closeWait()
        await server.closeWait()

      try:
        waitFor body()
        if naive:
          outcome = ProbeOutcome(ok: false,
            msg: "naive fixture completed cleanly; expected a deadlock " &
              "(the swallowed reset leaves responseFut incomplete forever)")
      except AssertionDefect as exc:
        if naive:
          outcome = ProbeOutcome(ok: true, msg: "RED (expected): " & exc.msg)
        else:
          outcome = ProbeOutcome(ok: false,
            msg: "fixed fixture still deadlocked: " & exc.msg)
      except CatchableError as exc:
        outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
      outcome

    proc probeDatagramResetFaultNaive() {.thread.} =
      probeChan.send(probeDatagramResetFaultProbe(naive = true))

    proc probeDatagramResetFaultFixed() {.thread.} =
      probeChan.send(probeDatagramResetFaultProbe(naive = false))

    suite "SimNet datagram endpoints":
      test "datagramPair mints a connected pair; a REQUEST/ANSWER round trip passes under sim":
        let outcome = runProbe(probeDatagramPairEchoUnderSim)
        checkpoint outcome.msg
        check outcome.ok

      test "reset fault: a naive fixture that swallows the read error deadlocks (RED, reproducible)":
        let outcome = runProbe(probeDatagramResetFaultNaive)
        checkpoint outcome.msg
        check outcome.ok

      test "reset fault: a fixture that fails the waiting future observes it cleanly (GREEN)":
        let outcome = runProbe(probeDatagramResetFaultFixed)
        checkpoint outcome.msg
        check outcome.ok
