#                  Tonalli Test Suite
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

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
  import ../tonalli
  import ../tonalli/simulation
  import ../tonalli/streams/asyncstream
  import ./simfixtures

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
    chunkSize = simnetFixtureChunkSize
    messages = simnetFixtureMessages

  proc toStr(b: seq[byte]): string =
    simnetFixtureToStr(b)

  proc runPipelinedEcho(client, server: StreamTransport):
      Future[seq[string]] {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
    ## The parametrized echo body itself now lives in
    ## `tests/simfixtures.nim` (RFC 0012 stage 6), shared with
    ## `tests/simreplay.nim`; this stays a thin same-signature wrapper
    ## so every other probe below keeps calling it by its original name.
    await simnetFixtureRunPipelinedEcho(client, server)

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

  proc probeReadinessTriggeredReadCarriesRealTrigger() {.thread.} =
    ## RFC 0003 3.3's `IoOutcomePoint.trigger` names the readiness event
    ## whose delivery is firing the callback that issues an I/O
    ## decision - a correlation `simStreamIo`/`simDatagramIo` never
    ## actually wired before this round (every production call site
    ## hardcoded `trigger: SimEventId(0)`, so a decision log could never
    ## answer "which event's callback issued this I/O"). A scripted
    ## `decideBatch` records the single delivered readiness id whenever
    ## exactly one is delivered in a poll iteration (the shape this
    ## scenario produces: the server's already-armed `readOnce` waking
    ## when the client's write lands); a scripted `decideIo` records the
    ## `trigger` the resulting read actually saw. The two must agree,
    ## and neither may be the `SimEventId(0)` placeholder. The
    ## snapshot is taken right after the awaited read, before
    ## `closeWait()`'s own EOF notification delivers a second, unrelated
    ## readiness event to the same still-armed reader - that later read
    ## is real too (this fix makes it carry its own real trigger, not
    ## the sentinel), just not the one this probe is pinning.
    var outcome = ProbeOutcome(ok: true)
    var lastSingleDelivery = SimEventId(0)
    var readTriggerCalls = 0
    var seenReadTrigger = SimEventId(0)
    var snapshotTriggerCalls = 0
    var snapshotTrigger = SimEventId(0)
    var snapshotDelivery = SimEventId(0)

    proc decideBatch(cp: SelectBatchPoint):
        Result[BatchDecision, SimOracleError] {.gcsafe, raises: [].} =
      let decision = defaultDecideBatch(cp)
      if decision.isOk and decision.get().order.len == 1:
        lastSingleDelivery = decision.get().order[0]
      decision

    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      if cp.op == SimIoOp.Read:
        inc readTriggerCalls
        seenReadTrigger = cp.trigger
      defaultDecideIo(cp)

    let oracle = newSimOracle(decideBatch, decideIo, defaultDecideTime)
    setThreadDispatcher(newSimDispatcher(oracle = oracle))

    proc body() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
      let net = simNet()
      let address = initTAddress("127.0.0.1:0")
      let server = net.listenStream(address)
      let acceptFut = server.accept()
      let client = await net.connectStream(address)
      let serverTransp = await acceptFut

      # Armed before the write lands, so the read below only completes
      # once a delivered `Readiness` event wakes it - not synchronously.
      var buf = newSeq[byte](chunkSize)
      let readFut = serverTransp.readOnce(addr buf[0], chunkSize)
      discard await client.write("message1")
      discard await readFut

      snapshotTriggerCalls = readTriggerCalls
      snapshotTrigger = seenReadTrigger
      snapshotDelivery = lastSingleDelivery

      await client.closeWait()
      await serverTransp.closeWait()

    try:
      waitFor body()
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)

    if outcome.ok:
      if snapshotTriggerCalls != 1:
        outcome = ProbeOutcome(ok: false,
          msg: "decideIo(Read) called " & $snapshotTriggerCalls &
            " times before the awaited read completed, expected 1")
      elif snapshotTrigger == SimEventId(0):
        outcome = ProbeOutcome(ok: false,
          msg: "readiness-triggered read carried trigger=" &
            $snapshotTrigger & " (the not-triggered placeholder), " &
            "expected the delivering event's real id")
      elif snapshotTrigger != snapshotDelivery:
        outcome = ProbeOutcome(ok: false,
          msg: "read trigger " & $snapshotTrigger & " does not match " &
            "the delivered readiness event id " & $snapshotDelivery)
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
        simnetPipelinedEchoUnderPartialCompletionsFixture()
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

    test "a readiness-triggered read carries the delivering event's real SimEventId as trigger":
      let outcome = runProbe(probeReadinessTriggeredReadCarriesRealTrigger)
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
