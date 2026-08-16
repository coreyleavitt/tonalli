#
#       Chronos multithreaded synchronization primitives
#
#  (c) Copyright 2023-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## This module implements some core async thread synchronization primitives.
import results
import "."/[config, timer, asyncloop]

export results

{.push raises: [].}

const hasThreadSupport = compileOption("threads")
when not(hasThreadSupport):
  {.fatal: "Compile this program with threads enabled!".}

import "."/[osdefs, osutils, oserrno]

when chronosSimulation:
  import ./internal/simengine
    # Fork issue #19 workstream 2's typed sim error channel: this
    # module's own `register2`/`unregister2`/`addReader2`/`removeReader2`/
    # `addWriter2`/`removeWriter2` calls (below) now raise `SimBarrierError`
    # directly under `-d:chronosSimulation` (`chronos/internal/
    # asyncengine.nim`) instead of threading a reserved error code -
    # `SimBarrierError` itself needs naming here to widen this module's
    # own `raises` lists. `ThreadSignalPtr.fire`/`wait` have zero internal
    # chronos callers (stage 3's own note), so this module's job is only
    # to compile correctly under the sim define with honest typed raises,
    # not to build a sim seam of its own the way `chronos/transports/
    # stream.nim`/`datagram.nim` do.

  # See `chronos/transports/stream.nim`'s own copy of this alias for the
  # toolchain quirks it works around.
  {.pragma: mayBarrier, raises: [SimBarrierError].}
else:
  {.pragma: mayBarrier, raises: [].}

when chronosSimulation and not defined(windows):
  {.pragma: mayBarrierPosix, raises: [SimBarrierError].}
else:
  {.pragma: mayBarrierPosix, raises: [].}

type
  ThreadSignal* = object
    when defined(windows):
      event: HANDLE
    elif defined(linux):
      efd: AsyncFD
    else:
      rfd, wfd: AsyncFD

  ThreadSignalPtr* = ptr ThreadSignal

proc new*(t: typedesc[ThreadSignalPtr]): Result[ThreadSignalPtr, string] =
  ## Create new ThreadSignal object.
  let res = cast[ptr ThreadSignal](allocShared0(sizeof(ThreadSignal)))
  when defined(windows):
    var sa = getSecurityAttributes()
    let event = osdefs.createEvent(addr sa, DWORD(0), DWORD(0), nil)
    if event == HANDLE(0):
      deallocShared(res)
      return err(osErrorMsg(osLastError()))
    res[] = ThreadSignal(event: event)
  elif defined(linux):
    let efd = eventfd(0, EFD_CLOEXEC or EFD_NONBLOCK)
    if efd == -1:
      deallocShared(res)
      return err(osErrorMsg(osLastError()))
    res[] = ThreadSignal(efd: AsyncFD(efd))
  else:
    var sockets: array[2, cint]
    block:
      let sres = socketpair(AF_UNIX, SOCK_DGRAM, 0, sockets)
      if sres < 0:
        deallocShared(res)
        return err(osErrorMsg(osLastError()))
    # MacOS do not have SOCK_NONBLOCK and SOCK_CLOEXEC, so we forced to use
    # setDescriptorFlags() for every socket.
    block:
      let sres = setDescriptorFlags(sockets[0], true, true)
      if sres.isErr():
        discard closeFd(sockets[0])
        discard closeFd(sockets[1])
        deallocShared(res)
        return err(osErrorMsg(sres.error))
    block:
      let sres = setDescriptorFlags(sockets[1], true, true)
      if sres.isErr():
        discard closeFd(sockets[0])
        discard closeFd(sockets[1])
        deallocShared(res)
        return err(osErrorMsg(sres.error))
    res[] = ThreadSignal(rfd: AsyncFD(sockets[0]), wfd: AsyncFD(sockets[1]))
  ok(ThreadSignalPtr(res))

when not(defined(windows)):
  type
    WaitKind {.pure.} = enum
      Read, Write

  when defined(linux):
    proc checkBusy(fd: cint): bool = false
  else:
    proc checkBusy(fd: cint): bool =
      var data = 0'u64
      let res = handleEintr(recv(SocketHandle(fd),
                                 addr data, sizeof(uint64), MSG_PEEK))
      if res == sizeof(uint64):
        true
      else:
        false

  func toTimeval(a: Duration): Timeval =
    ## Convert Duration ``a`` to ``Timeval`` object.
    let nanos = a.nanoseconds
    let m = nanos mod Second.nanoseconds()
    Timeval(
      tv_sec: Time(nanos div Second.nanoseconds()),
      tv_usec: Suseconds(m div Microsecond.nanoseconds())
    )

  proc waitReady(fd: cint, kind: WaitKind,
                 timeout: Duration): Result[bool, OSErrorCode] =
    var
      tv: Timeval
      fdset =
        block:
          var res: TFdSet
          FD_ZERO(res)
          FD_SET(SocketHandle(fd), res)
          res

    let
      ptv =
        if not(timeout.isInfinite()):
          tv = timeout.toTimeval()
          addr tv
        else:
          nil
      nfd = cint(fd) + 1
      res =
        case kind
        of WaitKind.Read:
          handleEintr(select(nfd, addr fdset, nil, nil, ptv))
        of WaitKind.Write:
          handleEintr(select(nfd, nil, addr fdset, nil, ptv))

    if res > 0:
      ok(true)
    elif res == 0:
      ok(false)
    else:
      err(osLastError())

  proc safeUnregisterAndCloseFd(fd: AsyncFD): Result[void, OSErrorCode]
                                {.mayBarrier.} =
    let loop = getThreadDispatcher()
    if loop.contains(fd):
      ? unregister2(fd)
    if closeFd(cint(fd)) != 0:
      err(osLastError())
    else:
      ok()

  # As `chronos/transports/stream.nim`'s own `simBoundaryGuard`/`safe*`
  # family: `fire`/`wait`'s `continuation`/`cancellation` closures below
  # are `CallbackFunc`s (`raises: []` by that fixed type, unwidenable per
  # build) that reach the registration guard `removeWriter2`/
  # `removeReader2` - a provably-unreachable `SimBarrierError` here (this
  # module never mints or touches a sim-owned fd; a real fd registered
  # under a simulated dispatcher is exactly the barrier condition these
  # guards exist to catch). Caught here, by type, and escalated to a
  # `Defect` (`raiseAsDefect`) instead of letting it propagate normally;
  # `chronos/simulation.nim`'s `runSimulation` unwraps it back into the
  # original typed error.
  template simBoundaryGuard(body: untyped): untyped =
    when chronosSimulation:
      try:
        body
      except SimBarrierError as excSimBoundary:
        raiseAsDefect(excSimBoundary,
          "simulation barrier reached from a CallbackFunc boundary")
    else:
      body

  proc safeRemoveWriter2(fd: AsyncFD): Result[void, OSErrorCode]
                         {.raises: [].} =
    simBoundaryGuard(removeWriter2(fd))

  proc safeRemoveReader2(fd: AsyncFD): Result[void, OSErrorCode]
                         {.raises: [].} =
    simBoundaryGuard(removeReader2(fd))

proc close*(signal: ThreadSignalPtr): Result[void, string] {.mayBarrierPosix.} =
  ## Close ThreadSignal object and free all the resources.
  defer: deallocShared(signal)
  when defined(windows):
    # We do not need to perform unregistering on Windows, we can only close it.
    if closeHandle(signal[].event) == 0'u32:
      return err(osErrorMsg(osLastError()))
  elif defined(linux):
    let res = safeUnregisterAndCloseFd(signal[].efd)
    if res.isErr():
      return err(osErrorMsg(res.error))
  else:
    let res1 = safeUnregisterAndCloseFd(signal[].rfd)
    let res2 = safeUnregisterAndCloseFd(signal[].wfd)
    if res1.isErr(): return err(osErrorMsg(res1.error))
    if res2.isErr(): return err(osErrorMsg(res2.error))
  ok()

proc fireSync*(signal: ThreadSignalPtr,
               timeout = InfiniteDuration): Result[bool, string] =
  ## Set state of ``signal`` to signaled state in blocking way.
  ##
  ## Returns ``false`` if signal was not signalled in time, and ``true``
  ## if operation was successful.
  when defined(windows):
    if setEvent(signal[].event) == 0'u32:
      return err(osErrorMsg(osLastError()))
    ok(true)
  else:
    let
      eventFd =
        when defined(linux):
          cint(signal[].efd)
        else:
          cint(signal[].wfd)
      checkFd =
        when defined(linux):
          cint(signal[].efd)
        else:
          cint(signal[].rfd)

    if checkBusy(checkFd):
      # Signal is already in signalled state
      return ok(true)

    var data = 1'u64
    while true:
      let res =
        when defined(linux):
          handleEintr(write(eventFd, addr data, sizeof(uint64)))
        else:
          handleEintr(send(SocketHandle(eventFd), addr data, sizeof(uint64),
                           MSG_NOSIGNAL))
      if res < 0:
        let errorCode = osLastError()
        case errorCode
        of EAGAIN:
          let wres = waitReady(eventFd, WaitKind.Write, timeout)
          if wres.isErr():
            return err(osErrorMsg(wres.error))
          if not(wres.get()):
            return ok(false)
        else:
          return err(osErrorMsg(errorCode))
      elif res != sizeof(data):
        return err(osErrorMsg(EINVAL))
      else:
        return ok(true)

proc waitSync*(signal: ThreadSignalPtr,
               timeout = InfiniteDuration): Result[bool, string] =
  ## Wait until the signal become signaled. This procedure is ``NOT`` async,
  ## so it blocks execution flow, but this procedure do not need asynchronous
  ## event loop to be present.
  when defined(windows):
    let
      timeoutWin =
        if timeout.isInfinite():
          INFINITE
        else:
          DWORD(timeout.milliseconds())
      handle = signal[].event
      res = waitForSingleObject(handle, timeoutWin)
    if res == WAIT_OBJECT_0:
      ok(true)
    elif res == WAIT_TIMEOUT:
      ok(false)
    elif res == WAIT_ABANDONED:
      err("The wait operation has been abandoned")
    else:
      err("The wait operation has been failed")
  else:
    let eventFd =
      when defined(linux):
        cint(signal[].efd)
      else:
        cint(signal[].rfd)
    var
      data = 0'u64
      timer = timeout
    while true:
      let wres =
        block:
          let
            start = Moment.now()
            res = waitReady(eventFd, WaitKind.Read, timer)
          timer = timer - (Moment.now() - start)
          res
      if wres.isErr():
        return err(osErrorMsg(wres.error))
      if not(wres.get()):
        return ok(false)
      let res =
        when defined(linux):
          handleEintr(read(eventFd, addr data, sizeof(uint64)))
        else:
          handleEintr(recv(SocketHandle(eventFd), addr data, sizeof(uint64),
                           cint(0)))
      if res < 0:
        let errorCode = osLastError()
        # If errorCode == EAGAIN it means that reading operation is already
        # pending and so some other consumer reading eventfd or pipe end, in
        # this case we going to ignore error and wait for another event.
        if errorCode != EAGAIN:
          return err(osErrorMsg(errorCode))
      elif res != sizeof(data):
        return err(osErrorMsg(EINVAL))
      else:
        return ok(true)

proc fire*(signal: ThreadSignalPtr): Future[void] {.
    async: (raises: [AsyncError, CancelledError], raw: true), mayBarrier.} =
  ## Set state of ``signal`` to signaled in asynchronous way.
  var retFuture = newFuture[void]("asyncthreadsignal.fire")
  when defined(windows):
    if setEvent(signal[].event) == 0'u32:
      retFuture.fail(newException(AsyncError, osErrorMsg(osLastError())))
    else:
      retFuture.complete()
  else:
    var data = 1'u64
    let
      eventFd =
        when defined(linux):
          cint(signal[].efd)
        else:
          cint(signal[].wfd)
      checkFd =
        when defined(linux):
          cint(signal[].efd)
        else:
          cint(signal[].rfd)

    proc continuation(udata: pointer) {.gcsafe, raises: [].} =
      if not(retFuture.finished()):
        let res =
          when defined(linux):
            handleEintr(write(eventFd, addr data, sizeof(uint64)))
          else:
            handleEintr(send(SocketHandle(eventFd), addr data, sizeof(uint64),
                             MSG_NOSIGNAL))
        if res < 0:
          let errorCode = osLastError()
          discard safeRemoveWriter2(AsyncFD(eventFd))
          retFuture.fail(newException(AsyncError, osErrorMsg(errorCode)))
        elif res != sizeof(data):
          discard safeRemoveWriter2(AsyncFD(eventFd))
          retFuture.fail(newException(AsyncError, osErrorMsg(EINVAL)))
        else:
          let eres = safeRemoveWriter2(AsyncFD(eventFd))
          if eres.isErr():
            retFuture.fail(newException(AsyncError, osErrorMsg(eres.error)))
          else:
            retFuture.complete()

    proc cancellation(udata: pointer) {.gcsafe, raises: [].} =
      if not(retFuture.finished()):
        discard safeRemoveWriter2(AsyncFD(eventFd))

    if checkBusy(checkFd):
      # Signal is already in signalled state
      retFuture.complete()
      return retFuture

    let res =
      when defined(linux):
        handleEintr(write(eventFd, addr data, sizeof(uint64)))
      else:
        handleEintr(send(SocketHandle(eventFd), addr data, sizeof(uint64),
                         MSG_NOSIGNAL))
    if res < 0:
      let errorCode = osLastError()
      case errorCode
      of EAGAIN:
        let loop = getThreadDispatcher()
        if not(loop.contains(AsyncFD(eventFd))):
          let rres = register2(AsyncFD(eventFd))
          if rres.isErr():
            retFuture.fail(newException(AsyncError, osErrorMsg(rres.error)))
            return retFuture
        let wres = addWriter2(AsyncFD(eventFd), continuation)
        if wres.isErr():
          retFuture.fail(newException(AsyncError, osErrorMsg(wres.error)))
        else:
          retFuture.cancelCallback = cancellation
      else:
        retFuture.fail(newException(AsyncError, osErrorMsg(errorCode)))
    elif res != sizeof(data):
      retFuture.fail(newException(AsyncError, osErrorMsg(EINVAL)))
    else:
      retFuture.complete()

  retFuture

when defined(windows):
  proc wait*(signal: ThreadSignalPtr) {.
      async: (raises: [AsyncError, CancelledError]).} =
    let handle = signal[].event
    let res = await waitForSingleObject(handle, InfiniteDuration)
    # There should be no other response, because we use `InfiniteDuration`.
    doAssert(res == WaitableResult.Ok)
else:
  proc wait*(signal: ThreadSignalPtr): Future[void] {.
      async: (raises: [AsyncError, CancelledError], raw: true), mayBarrier.} =
    let retFuture = Future[void].Raising([AsyncError, CancelledError]).init(
      "asyncthreadsignal.wait")
    var data = 1'u64
    let eventFd =
      when defined(linux):
        cint(signal[].efd)
      else:
        cint(signal[].rfd)

    proc continuation(udata: pointer) {.gcsafe, raises: [].} =
      if not(retFuture.finished()):
        let res =
          when defined(linux):
            handleEintr(read(eventFd, addr data, sizeof(uint64)))
          else:
            handleEintr(recv(SocketHandle(eventFd), addr data, sizeof(uint64),
                             cint(0)))
        if res < 0:
          let errorCode = osLastError()
          # If errorCode == EAGAIN it means that reading operation is already
          # pending and so some other consumer reading eventfd or pipe end, in
          # this case we going to ignore error and wait for another event.
          if errorCode != EAGAIN:
            discard safeRemoveReader2(AsyncFD(eventFd))
            retFuture.fail(newException(AsyncError, osErrorMsg(errorCode)))
        elif res != sizeof(data):
          discard safeRemoveReader2(AsyncFD(eventFd))
          retFuture.fail(newException(AsyncError, osErrorMsg(EINVAL)))
        else:
          let eres = safeRemoveReader2(AsyncFD(eventFd))
          if eres.isErr():
            retFuture.fail(newException(AsyncError, osErrorMsg(eres.error)))
          else:
            retFuture.complete()

    proc cancellation(udata: pointer) {.gcsafe, raises: [].} =
      if not(retFuture.finished()):
        # Future is already cancelled so we ignore errors.
        discard safeRemoveReader2(AsyncFD(eventFd))

    let loop = getThreadDispatcher()
    if not(loop.contains(AsyncFD(eventFd))):
      let res = register2(AsyncFD(eventFd))
      if res.isErr():
        retFuture.fail(newException(AsyncError, osErrorMsg(res.error)))
        return retFuture
    let res = addReader2(AsyncFD(eventFd), continuation)
    if res.isErr():
      retFuture.fail(newException(AsyncError, osErrorMsg(res.error)))
      return retFuture
    retFuture.cancelCallback = cancellation
    retFuture
