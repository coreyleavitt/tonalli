#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for `chronos/internal/simengine.nim` (the fd provenance table,
## the reserved barrier code and its helpers, `SimBarrierError`) and,
## under `-d:chronosSimulation`, the `Dispatcher` construction fork and
## provenance guard installed in `chronos/internal/asyncengine.nim`.

import unittest2
import ../chronos/oserrno
import ../chronos/internal/simengine

when defined(chronosSimulation):
  import std/heapqueue
  import ../chronos
  import ../chronos/config

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

  test "isSimBarrier recognizes only the reserved code":
    check isSimBarrier(SimBarrierCode)
    check not isSimBarrier(OSErrorCode(0))

  test "raiseIfSimBarrier raises for the reserved code, is a no-op otherwise":
    expect SimBarrierError:
      raiseIfSimBarrier(SimBarrierCode)
    raiseIfSimBarrier(OSErrorCode(0))

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
    if not disp.getIoHandler().isNil:
      outcome = ProbeOutcome(ok: false, msg: "selector was not nil")
    elif not disp.isSimDispatcher():
      outcome = ProbeOutcome(ok: false, msg: "isSimDispatcher() was false")
    elif disp.timers.len() != 0:
      outcome = ProbeOutcome(ok: false, msg: "timer heap was not empty")
    probeChan.send(outcome)

  proc probeAddReaderBarrier() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    let res = addReader2(AsyncFD(999_999), dummyCb)
    if res.isOk():
      outcome = ProbeOutcome(ok: false, msg: "addReader2 unexpectedly succeeded")
    elif res.error() != SimBarrierCode:
      outcome = ProbeOutcome(ok: false, msg: "wrong error code returned")
    else:
      try:
        raiseIfSimBarrier(res.error())
        outcome = ProbeOutcome(ok: false, msg: "raiseIfSimBarrier did not raise")
      except SimBarrierError:
        discard
    probeChan.send(outcome)

  proc probeUnregisterBarrier() {.thread.} =
    var outcome = ProbeOutcome(ok: true)
    setThreadDispatcher(newSimDispatcher())
    let res = unregister2(AsyncFD(999_999))
    if res.isOk() or res.error() != SimBarrierCode:
      outcome = ProbeOutcome(ok: false, msg: "unregister2 did not barrier")
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
      let res = addSignal2(1, dummyCb)
      if res.isOk() or res.error() != SimBarrierCode:
        outcome = ProbeOutcome(ok: false, msg: "addSignal2 did not barrier")
      probeChan.send(outcome)

  suite "sim dispatcher construction and provenance guard":
    test "construction touches no selector":
      let outcome = runProbe(probeConstruction)
      checkpoint outcome.msg
      check outcome.ok

    test "addReader2 with a real fd returns the reserved barrier code":
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
