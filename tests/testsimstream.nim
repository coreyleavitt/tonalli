#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/transports/stream.nim`'s injectable I/O primitive
## (RFC 0003 3.2 N4, slice S10): `fastWrite`'s eager call site, answered
## inline by a scripted `decideIo` with no fd ever touched, and the
## `SimFault` translation that keeps a faulted outcome flowing through
## the same real-mode error-classification logic.

{.used.}

when defined(chronosSimulation) and compileOption("threads") and
    not defined(windows):
  import unittest2
  import results
  import ../chronos
  import ../chronos/internal/simengine

  ## Every probe below runs on a freshly spawned OS thread so its
  ## `setThreadDispatcher` call never touches this test binary's real
  ## per-thread dispatcher (the established pattern - see
  ## tests/testsimengine.nim).
  ##
  ## POSIX-only: `fastWrite`'s eager path - what these probes drive
  ## through the seam - has never existed on Windows, in any build,
  ## sim or real (`stream.nim`'s `fastWrite` template is a deliberate
  ## no-op there; RFC 0003 3.2's fastWrite passage and section 4's
  ## Windows IOCP-emulation non-goal both name this). A probe asserting
  ## the eager path engaged would be asserting something structurally
  ## false on Windows, not exercising an unseamed gap - guarding it
  ## here keeps the suite honest about what S10 covers per platform
  ## instead of compiling an assertion that could never pass there.
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

  proc freshSimPipeFd(disp: PDispatcher): AsyncFD =
    ## Mints and discards fd 0/1/2 (real stdio values) so the id this
    ## returns can never coincide with the test process's own stdio: a
    ## pre-seam accidental fallthrough to a real syscall on one of
    ## those values could misleadingly succeed instead of failing
    ## loudly, which would make the RED phase's failure ambiguous.
    discard disp.mintSimFd()
    discard disp.mintSimFd()
    discard disp.mintSimFd()
    disp.mintSimFd()

  proc probeFastWriteFullCompletion() {.thread.} =
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
    let fd = freshSimPipeFd(disp)

    try:
      let transp = fromPipe(fd)
      let fut = transp.write("hello")

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
      elif not fut.finished():
        outcome = ProbeOutcome(ok: false,
          msg: "write() future did not complete synchronously - a real " &
            "syscall was attempted instead of an inline decideIo answer")
      elif fut.failed():
        outcome = ProbeOutcome(ok: false,
          msg: "write() future failed instead of completing")
      elif fut.read() != 5:
        outcome = ProbeOutcome(ok: false,
          msg: "write() completed with " & $fut.read() & " bytes, expected 5")
    except TransportOsError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc probeFastWriteFault() {.thread.} =
    var outcome = ProbeOutcome(ok: true)

    proc decideIo(cp: IoOutcomePoint): Result[IoDecision, SimOracleError]
        {.gcsafe, raises: [].} =
      ok(IoDecision(outcome: SimIoOutcome.Fault, fault: SimFault.Reset))

    let oracle = newSimOracle(defaultDecideBatch, decideIo, defaultDecideTime)
    let disp = newSimDispatcher(oracle = oracle)
    setThreadDispatcher(disp)
    let fd = freshSimPipeFd(disp)

    try:
      let transp = fromPipe(fd)
      let fut = transp.write("hello")

      if not fut.finished():
        outcome = ProbeOutcome(ok: false,
          msg: "write() future did not complete synchronously")
      elif fut.failed():
        outcome = ProbeOutcome(ok: false,
          msg: "write() future failed instead of completing 0 (the same " &
            "WriteEof treatment a real ECONNRESET gets)")
      elif fut.read() != 0:
        outcome = ProbeOutcome(ok: false,
          msg: "write() completed with " & $fut.read() &
            " bytes, expected 0")
      elif not transp.finished():
        outcome = ProbeOutcome(ok: false,
          msg: "transport was not marked WriteEof after the fault")
    except TransportOsError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  suite "sim stream I/O seam":
    test "fastWrite routes through decideIo, answered inline":
      let outcome = runProbe(probeFastWriteFullCompletion)
      checkpoint outcome.msg
      check outcome.ok

    test "fastWrite's Fault outcome flows through real error handling":
      let outcome = runProbe(probeFastWriteFault)
      checkpoint outcome.msg
      check outcome.ok
