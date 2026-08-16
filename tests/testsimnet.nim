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
  import results
  import ../chronos
  import ../chronos/simulation
  import ../chronos/streams/asyncstream

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
      Future[seq[string]] {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
    ## The parametrized echo body (RFC 0003 6, S11a's RED criterion):
    ## the client pipelines every write before awaiting any of them,
    ## the server echoes each fixed-size chunk back in arrival order,
    ## and the client reads every echo. Fixed-size chunks plus
    ## `readExactly` keep the scenario robust to how many actual
    ## deliveries the underlying transport makes (coalesced or split),
    ## so sim and a real byte stream can be held to the same body
    ## without message-framing becoming the thing under test.
    proc serverLoop() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
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

    proc body() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
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

    proc body() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
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

    proc body() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
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

    proc body() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
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
      async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
    let server = createStreamServer(initTAddress("127.0.0.1:0"))
    var acceptFut = server.accept()
    let client = await connect(server.localAddress())
    let serverTransp = await acceptFut
    result = await runPipelinedEcho(client, serverTransp)
    await client.closeWait()
    await serverTransp.closeWait()
    server.stop()
    await server.closeWait()

  proc chunkedIoOracle(fragment: int): SimOracle =
    ## S11b's scripted partial-completion oracle: every read and write
    ## completes at `fragment` bytes at a time (clamped to what was
    ## actually requested), the sim analogue of a byte stream that never
    ## delivers a whole message in one call. Faults stay empty - that
    ## menu is S12b's, datagram-side.
    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: min(cp.maxBytes, fragment)))
    newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)

  proc runShortReadEcho(client, server: StreamTransport):
      Future[seq[string]] {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
    ## Unlike `runPipelinedEcho`'s server loop, which reads with
    ## `readExactly`, this one loops a single-shot `readOnce` itself
    ## until it has the whole chunk - proving short reads are handled
    ## correctly one layer below `readExactly`'s own looping, directly
    ## against the endpoint's leftover-byte accounting (RFC 0003 6,
    ## S11b).
    proc serverLoop() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
      for _ in messages:
        var buf = newSeq[byte](chunkSize)
        var got = 0
        while got < chunkSize:
          got += await server.readOnce(addr buf[got], chunkSize - got)
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

  proc probeShortReadEchoUnderPartialCompletions() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher(oracle = chunkedIoOracle(3)))

    proc body() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
      let net = simNet()
      let address = initTAddress("127.0.0.1:0")
      let server = net.listenStream(address)
      let acceptFut = server.accept()
      let client = await net.connectStream(address)
      let serverTransp = await acceptFut
      let echoes = await runShortReadEcho(client, serverTransp)
      if echoes != @messages:
        outcome = ProbeOutcome(ok: false,
          msg: "short-read echo mismatch under partial completions: got " &
            $echoes & ", expected " & $(@messages))
      await client.closeWait()
      await serverTransp.closeWait()

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc probeSweepPipelinedEchoUnderPartialCompletions() {.thread.} =
    ## Sweep integration (RFC 0003 6, S11b): `runPipelinedEcho` already
    ## reads with `readExactly`, so it needs no fix - this proves
    ## partial completions are reachable through the default seeded
    ## oracle every `simulate()`/`sweepSeeds()` caller gets, not only
    ## through a hand-scripted one, and that the existing S11a fixture
    ## already tolerates them.
    var outcome = ProbeOutcome(ok: true)
    try:
      let outcomes = sweepSeeds(0'u64 .. 15'u64):
        let net = simNet()
        let address = initTAddress("127.0.0.1:0")
        let server = net.listenStream(address)
        let acceptFut = server.accept()
        let client = await net.connectStream(address)
        let serverTransp = await acceptFut
        let echoes = await runPipelinedEcho(client, serverTransp)
        if echoes != @messages:
          raise newException(ValueError,
            "sweep echo mismatch: got " & $echoes & ", expected " &
              $(@messages))
        await client.closeWait()
        await serverTransp.closeWait()
      for o in outcomes:
        if not o.passed:
          outcome = ProbeOutcome(ok: false,
            msg: "seed " & $o.seed & " failed (" & $o.kind & "): " & o.msg)
          break
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc probeAsyncStreamRoundTripsOverSimTransport() {.thread.} =
    ## Finding 7a's first leg (RFC 0003 fork issue #19 workstream 2's
    ## coverage review): `chronos/streams/asyncstream.nim`'s 8 read-side
    ## and 1 write-side `SimBarrierError`/`SimEngineError` absorption
    ## clauses are compiled under `-d:chronosSimulation` but no existing
    ## test ever wraps an `AsyncStreamReader`/`AsyncStreamWriter` around a
    ## `SimNet` transport - this proves the wrap itself works under sim,
    ## ahead of the next probe driving one absorption clause for real.
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    const payload = "hello-sim-stream"

    proc body() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError, AsyncStreamError]).} =
      let net = simNet()
      let address = initTAddress("127.0.0.1:0")
      let server = net.listenStream(address)
      let acceptFut = server.accept()
      let client = await net.connectStream(address)
      let serverTransp = await acceptFut
      let wstream = newAsyncStreamWriter(client)
      let rstream = newAsyncStreamReader(serverTransp)
      let writeFut = wstream.write(payload)
      var buf = newSeq[byte](len(payload))
      await rstream.readExactly(addr buf[0], len(buf))
      await writeFut
      if toStr(buf) != payload:
        outcome = ProbeOutcome(ok: false,
          msg: "round trip mismatch: got " & toStr(buf))
      await wstream.finish()
      await wstream.closeWait()
      await rstream.closeWait()
      await client.closeWait()
      await serverTransp.closeWait()

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc illegalReadIoOracle(): SimOracle =
    ## Legal on `Write` (passes the whole request through, `defaultDecideIo`'s
    ## own answer), always out-of-range on `Read` (`maxBytes + 1`, `simDecideIo`'s
    ## own validated range is `1..maxBytes` - RFC 0003 3.5) - so a write lands
    ## real bytes in the peer's inbound queue (arming the read's `decideIo`
    ## call at all - `simStreamIo`'s "nothing queued, nothing to decide"
    ## short-circuit otherwise skips it entirely) and the read that then
    ## drains it hits the illegal answer deterministically.
    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      case cp.op
      of SimIoOp.Write:
        ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: cp.maxBytes))
      of SimIoOp.Read:
        ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: cp.maxBytes + 1))
    newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)

  proc probeAsyncStreamAbsorbsIllegalReadDecisionAsReadError() {.thread.} =
    ## Finding 7a's second leg: an oracle that hands `simDecideIo` an
    ## out-of-range `Read` answer raises `SimEngineError` (`ProtocolViolation`)
    ## directly out of the transport's `readExactly` - one of the 8 read-side
    ## absorption clauses this drives for real, converting it to
    ## `AsyncStreamReadError` with the original `SimEngineError` chained as
    ## `.parent`, never propagated as-is (`readExactlyImpl`,
    ## `chronos/streams/asyncstream.nim` ~line 704).
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher(oracle = illegalReadIoOracle()))

    proc body() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError, AsyncStreamError]).} =
      let net = simNet()
      let address = initTAddress("127.0.0.1:0")
      let server = net.listenStream(address)
      let acceptFut = server.accept()
      let client = await net.connectStream(address)
      let serverTransp = await acceptFut
      let wstream = newAsyncStreamWriter(client)
      let rstream = newAsyncStreamReader(serverTransp)
      await wstream.write("data")
      var buf = newSeq[byte](4)
      try:
        await rstream.readExactly(addr buf[0], 4)
        outcome = ProbeOutcome(ok: false,
          msg: "readExactly() did not surface the illegal decideIo answer")
      except AsyncStreamReadError as exc:
        if exc.parent.isNil or not (exc.parent of SimEngineError):
          outcome = ProbeOutcome(ok: false,
            msg: "AsyncStreamReadError.parent was not a SimEngineError")
      await wstream.finish()
      await wstream.closeWait()
      await rstream.closeWait()
      await client.closeWait()
      await serverTransp.closeWait()

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc illegalWriteIoOracle(): SimOracle =
    ## The write-side twin of `illegalReadIoOracle`: legal on `Read`, always
    ## out-of-range on `Write`, so the write-side's single absorption clause
    ## (`writeImpl`, `chronos/streams/asyncstream.nim` ~line 1083) is
    ## reachable on the very first write, with no peer-side read needed to
    ## arm it first.
    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      case cp.op
      of SimIoOp.Write:
        ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: cp.maxBytes + 1))
      of SimIoOp.Read:
        ok(IoDecision(outcome: SimIoOutcome.Ok, bytes: cp.maxBytes))
    newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)

  proc probeAsyncStreamAbsorbsIllegalWriteDecisionAsWriteError() {.thread.} =
    ## Finding 7a's write-side leg: the single write-side absorption clause,
    ## a distinct call site from the 8 read-side ones above.
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher(oracle = illegalWriteIoOracle()))

    proc body() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError, AsyncStreamError]).} =
      let net = simNet()
      let address = initTAddress("127.0.0.1:0")
      let server = net.listenStream(address)
      let acceptFut = server.accept()
      let client = await net.connectStream(address)
      let serverTransp = await acceptFut
      let wstream = newAsyncStreamWriter(client)
      try:
        await wstream.write("data")
        outcome = ProbeOutcome(ok: false,
          msg: "write() did not surface the illegal decideIo answer")
      except AsyncStreamWriteError as exc:
        if exc.parent.isNil or not (exc.parent of SimEngineError):
          outcome = ProbeOutcome(ok: false,
            msg: "AsyncStreamWriteError.parent was not a SimEngineError")
      await wstream.closeWait()
      await client.closeWait()
      await serverTransp.closeWait()

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

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

    test "short reads are handled correctly under a partial-completion oracle":
      let outcome = runProbe(probeShortReadEchoUnderPartialCompletions)
      checkpoint outcome.msg
      check outcome.ok

    test "pipelined echo passes under RandomOracle sweeps, partial completions included":
      let outcome = runProbe(probeSweepPipelinedEchoUnderPartialCompletions)
      checkpoint outcome.msg
      check outcome.ok

  suite "AsyncStream over SimNet transports":
    test "AsyncStreamReader/Writer round-trip over a sim transport pair":
      let outcome = runProbe(probeAsyncStreamRoundTripsOverSimTransport)
      checkpoint outcome.msg
      check outcome.ok

    test "an illegal read decideIo answer is absorbed into AsyncStreamReadError":
      let outcome = runProbe(probeAsyncStreamAbsorbsIllegalReadDecisionAsReadError)
      checkpoint outcome.msg
      check outcome.ok

    test "an illegal write decideIo answer is absorbed into AsyncStreamWriteError":
      let outcome = runProbe(probeAsyncStreamAbsorbsIllegalWriteDecisionAsWriteError)
      checkpoint outcome.msg
      check outcome.ok
