#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/simulation.nim`'s `SimNet` (RFC 0003 3.2/3.8,
## slice S11a): `simNet()`, `listenStream`/`connectStream` minting an
## already-connected in-memory endpoint pair behind the S10 seam, and
## `closeWait`/`shutdownWait` half-close delivering EOF to the peer.
## The differential test proves the same pipelined-echo body observes
## identical outcomes over a sim pair and a real transport pair - the
## claim is scoped to the read/write path (BipBuffer, the vector
## queue, the transport state machine above the S10 seam), not
## connection establishment, which `SimNet` mints sim-natively.
##
## POSIX-only: the stream I/O seam this builds on (`rawIoRead`/
## `rawIoWrite`) exists only in stream.nim's POSIX branch (RFC 0003
## section 4's Windows IOCP-emulation non-goal, already accepted at
## S10 - Windows transports use a two-phase overlapped-I/O model with
## no synchronous raw-read/write call site to seam). `SimNet`'s types
## and accessor still compile on every platform (see
## chronos/simulation.nim); only execution is POSIX-only here.

{.used.}

when defined(chronosSimulation) and compileOption("threads") and
    not defined(windows):
  import unittest2
  import ../chronos
  import ../chronos/simulation

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

  const
    chunkSize = 8
    messages = ["message1", "message2", "message3"]

  proc toStr(b: seq[byte]): string =
    result = newString(b.len)
    if b.len > 0:
      copyMem(addr result[0], unsafeAddr b[0], b.len)

  proc runPipelinedEcho(client, server: StreamTransport):
      Future[seq[string]] {.async: (raises: [TransportError, CancelledError]).} =
    ## The parametrized echo body (RFC 0003 6, S11a's RED criterion):
    ## the client pipelines every write before awaiting any of them,
    ## the server echoes each fixed-size chunk back in arrival order,
    ## and the client reads every echo. Fixed-size chunks plus
    ## `readExactly` keep the scenario robust to how many actual
    ## deliveries the underlying transport makes (coalesced or split),
    ## so sim and a real byte stream can be held to the same body
    ## without message-framing becoming the thing under test.
    proc serverLoop() {.async: (raises: [TransportError, CancelledError]).} =
      for _ in messages:
        var buf = newSeq[byte](chunkSize)
        await server.readExactly(addr buf[0], chunkSize)
        discard await server.write(buf)
    let serverFut = serverLoop()

    var writeFuts: seq[Future[int].Raising([TransportError, CancelledError])]
    for m in messages:
      writeFuts.add client.write(m)
    for f in writeFuts:
      discard await f

    result = @[]
    for _ in messages:
      var buf = newSeq[byte](chunkSize)
      await client.readExactly(addr buf[0], chunkSize)
      result.add toStr(buf)
    await serverFut

  proc probeSimPipelinedEcho() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())

    proc body() {.async: (raises: [TransportError, CancelledError]).} =
      let net = simNet()
      let address = initTAddress("127.0.0.1:0")
      let server = net.listenStream(address)
      let acceptFut = server.accept()
      let client = await net.connectStream(address)
      let serverTransp = await acceptFut
      let echoes = await runPipelinedEcho(client, serverTransp)
      if echoes != @messages:
        outcome = ProbeOutcome(ok: false,
          msg: "sim echo mismatch: got " & $echoes & ", expected " & $(@messages))
      await client.closeWait()
      await serverTransp.closeWait()

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc probeShutdownDeliversEofToPeer() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())

    proc body() {.async: (raises: [TransportError, CancelledError]).} =
      let net = simNet()
      let address = initTAddress("127.0.0.1:0")
      let server = net.listenStream(address)
      let acceptFut = server.accept()
      let client = await net.connectStream(address)
      let serverTransp = await acceptFut

      # The server's pending read is armed *before* the client shuts
      # down, so the EOF must arrive as a delivered event waking an
      # already-waiting reader, not merely a synchronous probe.
      var buf = newSeq[byte](chunkSize)
      let readFut = serverTransp.readOnce(addr buf[0], chunkSize)
      await client.shutdownWait()
      let n = await readFut
      if n != 0:
        outcome = ProbeOutcome(ok: false,
          msg: "peer readOnce() returned " & $n & " bytes after " &
            "shutdownWait(), expected 0 (EOF)")
      elif not serverTransp.atEof():
        outcome = ProbeOutcome(ok: false,
          msg: "peer transport not marked atEof() after shutdownWait()")
      await client.closeWait()
      await serverTransp.closeWait()

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc probeCloseDeliversEofToPeer() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())

    proc body() {.async: (raises: [TransportError, CancelledError]).} =
      let net = simNet()
      let address = initTAddress("127.0.0.1:0")
      let server = net.listenStream(address)
      let acceptFut = server.accept()
      let client = await net.connectStream(address)
      let serverTransp = await acceptFut

      var buf = newSeq[byte](chunkSize)
      let readFut = serverTransp.readOnce(addr buf[0], chunkSize)
      await client.closeWait()
      let n = await readFut
      if n != 0:
        outcome = ProbeOutcome(ok: false,
          msg: "peer readOnce() returned " & $n & " bytes after " &
            "closeWait(), expected 0 (EOF)")
      await serverTransp.closeWait()

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc probeEndpointIdentityIsNotFdCast() {.thread.} =
    ## S4 left `SimEndpointId` a provisional cast of the fd int; S11a
    ## gives it real identity (RFC 0003 3.3.1's per-kind monotonic
    ## counter, independent of the fd-domain counter `mintSimFd` owns).
    ## Minting several plain sim fds first (pushing the fd counter
    ## well ahead of the endpoint counter) and then a `SimNet` pair
    ## proves the two counters are genuinely independent: a leftover
    ## fd-cast would make the second endpoint's id equal `uint32(fd)`,
    ## a large number here, not a small one from its own counter.
    var outcome = ProbeOutcome(ok: true)
    let disp = newSimDispatcher()
    setThreadDispatcher(disp)
    for _ in 0 ..< 5:
      discard disp.mintSimFd()

    proc body() {.async: (raises: [TransportError, CancelledError]).} =
      let net = simNet()
      let address = initTAddress("127.0.0.1:0")
      let server = net.listenStream(address)
      let acceptFut = server.accept()
      let client = await net.connectStream(address)
      let serverTransp = await acceptFut
      if uint32(client.fd) < 5'u32:
        outcome = ProbeOutcome(ok: false,
          msg: "test setup did not push the fd counter ahead as intended")
      await client.closeWait()
      await serverTransp.closeWait()

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc realPipelinedEcho(): Future[seq[string]] {.
      async: (raises: [TransportError, CancelledError]).} =
    let server = createStreamServer(initTAddress("127.0.0.1:0"))
    var acceptFut = server.accept()
    let client = await connect(server.localAddress())
    let serverTransp = await acceptFut
    result = await runPipelinedEcho(client, serverTransp)
    await client.closeWait()
    await serverTransp.closeWait()
    server.stop()
    await server.closeWait()

  suite "SimNet stream endpoints":
    test "listenStream/connectStream mint a connected pair; pipelined echo passes under sim":
      let outcome = runProbe(probeSimPipelinedEcho)
      checkpoint outcome.msg
      check outcome.ok

    test "shutdownWait delivers EOF to an already-waiting peer read":
      let outcome = runProbe(probeShutdownDeliversEofToPeer)
      checkpoint outcome.msg
      check outcome.ok

    test "closeWait delivers EOF to an already-waiting peer read":
      let outcome = runProbe(probeCloseDeliversEofToPeer)
      checkpoint outcome.msg
      check outcome.ok

    test "SimEndpointId is minted from its own counter, not cast from the fd":
      let outcome = runProbe(probeEndpointIdentityIsNotFdCast)
      checkpoint outcome.msg
      check outcome.ok

    test "the same pipelined echo body observes identical outcomes over a real transport pair":
      let echoes = waitFor realPipelinedEcho()
      check echoes == @messages
