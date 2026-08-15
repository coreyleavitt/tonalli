#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/internal/simengine.nim` (the fd provenance table
## and `SimBarrierError`/`raiseSimBarrier`, the typed failure a
## provenance-guarded touch site raises directly at the point of
## detection) and, under `-d:chronosSimulation`, the `Dispatcher`
## construction fork and provenance guard installed in
## `chronos/internal/asyncengine.nim`.

import unittest2
import std/strutils
import ../chronos/oserrno
import ../chronos/futures
import ../chronos/internal/simengine

when defined(chronosSimulation):
  import std/heapqueue
  import ../chronos
  import ../chronos/config
  when defined(windows):
    import ../chronos/osdefs

{.used.}

suite "sim engine state":
  test "minted ids are recorded as owned":
    let state = newSimEngineState()
    let id = state.mintSimFd()
    check state.ownsSimFd(id)
    check not state.ownsSimFd(id + 1_000)

  test "minting skips the OS sentinel value":
    let state = newSimEngineState(startValue = -1)
    let id = state.mintSimFd()
    check id != -1
    check state.ownsSimFd(id)

  test "raiseSimBarrier raises SimBarrierError naming the touch site":
    try:
      raiseSimBarrier("test-site")
    except SimBarrierError as exc:
      check "test-site" in exc.msg

when defined(chronosSimulation) and compileOption("threads"):
  ## Every dispatcher-construction / provenance-guard probe below runs on
  ## a freshly spawned OS thread so its `setThreadDispatcher` calls never
  ## touch this test binary's real per-thread dispatcher (shared, via
  ## the `gDisp` threadvar, with every other suite `testall.nim` links
  ## into the same process).
  type
    ProbeOutcome = object
      ok: bool
      msg: string

  proc dummyCb(arg: pointer) {.gcsafe, raises: [].} =
    discard

  var probeChan: Channel[ProbeOutcome]
  probeChan.open()

  template runProbe(threadProc: typed): ProbeOutcome =
    var probeThread: Thread[void]
    createThread(probeThread, threadProc)
    let outcome = probeChan.recv()
    joinThread(probeThread)
    outcome

  proc probeConstruction() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let disp = newSimDispatcher()
    # `getIoHandler()` returns a POSIX `Selector` ref on POSIX
    # (`.isNil`-checkable) and a Windows `HANDLE` (`distinct uint`, no
    # `.isNil`) on Windows - both are checked against their own
    # untouched zero value, the platform-honest form of the same
    # construction guarantee (RFC 0003 3.5's `selector`/`ioPort` fork).
    let ioHandlerIsZero =
      when defined(windows):
        disp.getIoHandler() == HANDLE(0)
      else:
        disp.getIoHandler().isNil
    if not ioHandlerIsZero:
      outcome = ProbeOutcome(ok: false, msg: "selector was not nil")
    elif not disp.isSimDispatcher():
      outcome = ProbeOutcome(ok: false, msg: "isSimDispatcher() was false")
    elif disp.timers.len() != 0:
      outcome = ProbeOutcome(ok: false, msg: "timer heap was not empty")
    probeChan.send(outcome)

  proc probeAddReaderBarrier() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    try:
      discard addReader2(AsyncFD(999_999), dummyCb)
      outcome = ProbeOutcome(ok: false, msg: "addReader2 unexpectedly succeeded")
    except SimBarrierError:
      discard
    probeChan.send(outcome)

  proc probeUnregisterBarrier() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    try:
      discard unregister2(AsyncFD(999_999))
      outcome = ProbeOutcome(ok: false, msg: "unregister2 unexpectedly succeeded")
    except SimBarrierError:
      discard
    probeChan.send(outcome)

  proc probeContainsOwnership() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let disp = newSimDispatcher()
    setThreadDispatcher(disp)
    let minted = disp.mintSimFd()
    if not disp.contains(minted):
      outcome = ProbeOutcome(ok: false, msg: "contains() missed a minted fd")
    elif disp.contains(AsyncFD(999_999)):
      outcome = ProbeOutcome(ok: false, msg: "contains() claimed a non-owned fd")
    probeChan.send(outcome)

  proc probeCloseSocketNoCrash() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    try:
      closeSocket(AsyncFD(999_999))
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false, msg: "unexpected raise: " & exc.msg)
    probeChan.send(outcome)

  proc probeHandleBarrier() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    let disp = newSimDispatcher()
    setThreadDispatcher(disp)
    try:
      discard disp.handle()
      outcome = ProbeOutcome(ok: false, msg: "handle() did not refuse")
    except SimBarrierError:
      discard
    probeChan.send(outcome)

  when chronosEventEngine in ["epoll", "kqueue"]:
    proc probeSignalBarrier() {.thread.} =
      var outcome = ProbeOutcome(ok: true)
      setThreadDispatcher(newSimDispatcher())
      try:
        discard addSignal2(1, dummyCb)
        outcome = ProbeOutcome(ok: false, msg: "addSignal2 unexpectedly succeeded")
      except SimBarrierError:
        discard
      probeChan.send(outcome)

  suite "sim dispatcher construction and provenance guard":
    test "construction touches no selector":
      let outcome = runProbe(probeConstruction)
      checkpoint outcome.msg
      check outcome.ok

    test "addReader2 with a real fd raises SimBarrierError":
      let outcome = runProbe(probeAddReaderBarrier)
      checkpoint outcome.msg
      check outcome.ok

    test "unregister2 with a real fd barriers the same way":
      let outcome = runProbe(probeUnregisterBarrier)
      checkpoint outcome.msg
      check outcome.ok

    test "contains answers from the sim endpoint table, never a nil selector":
      let outcome = runProbe(probeContainsOwnership)
      checkpoint outcome.msg
      check outcome.ok

    test "closeSocket never dies with a NilAccessDefect":
      let outcome = runProbe(probeCloseSocketNoCrash)
      checkpoint outcome.msg
      check outcome.ok

    test "handle() refuses to mint a DispatcherHandle for a sim dispatcher":
      let outcome = runProbe(probeHandleBarrier)
      checkpoint outcome.msg
      check outcome.ok

    when chronosEventEngine in ["epoll", "kqueue"]:
      test "addSignal2 barriers unconditionally under simulation":
        let outcome = runProbe(probeSignalBarrier)
        checkpoint outcome.msg
        check outcome.ok

## S11b (RFC 0003 6): `simMintStreamPair`/`simStreamIo`/`simDeliverableEvents`
## are platform-neutral `SimEngineState` primitives (unlike
## `chronos/transports/stream.nim`'s POSIX-only `simStreamPair` wiring), so
## these run against a bare engine state, no dispatcher or thread needed -
## the same style `tests/testsimoracle.nim` already uses for `decideIo`.
proc dummyReaderCb(arg: pointer) {.gcsafe, raises: [].} =
  discard

suite "SimNet endpoint partial reads":
  test "a partial read leaves the reader armed for the leftover bytes":
    let state = newSimEngineState()
    let (fdA, fdB) = state.simMintStreamPair()
    state.simSetReaderInterest(fdB, bareCallback(dummyReaderCb))

    var payload = @[1'u8, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    let (wres, werr) = state.simStreamIo(fdA, SimIoOp.Write, addr payload[0],
                                          payload.len)
    check wres == 10
    check werr == OSErrorCode(0)

    let delivered = state.simDeliverableEvents()
    check delivered.len == 1
    discard state.simTakeDelivery(delivered[0].id)

    var buf = newSeq[byte](10)
    let (rres, rerr) = state.simStreamIo(fdB, SimIoOp.Read, addr buf[0], 3)
    check rres == 3
    check rerr == OSErrorCode(0)

    # 7 bytes remain queued: the reader must be re-armed so a later
    # decision can deliver them, not left waiting for an event that will
    # now never come.
    let after = state.simDeliverableEvents()
    check after.len == 1

  test "a read draining everything available does not spuriously re-arm the reader":
    let state = newSimEngineState()
    let (fdA, fdB) = state.simMintStreamPair()
    state.simSetReaderInterest(fdB, bareCallback(dummyReaderCb))

    var payload = @[1'u8, 2, 3, 4, 5]
    let (wres, werr) = state.simStreamIo(fdA, SimIoOp.Write, addr payload[0],
                                          payload.len)
    check wres == 5
    check werr == OSErrorCode(0)

    let delivered = state.simDeliverableEvents()
    discard state.simTakeDelivery(delivered[0].id)

    var buf = newSeq[byte](5)
    let (rres, rerr) = state.simStreamIo(fdB, SimIoOp.Read, addr buf[0], 5)
    check rres == 5
    check rerr == OSErrorCode(0)

    check state.simDeliverableEvents().len == 0
