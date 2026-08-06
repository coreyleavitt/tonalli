#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Async propagation tests for chronos contextvars.
## These exercise the dispatcher integration (capture-at-scheduling +
## restore-at-fire). The sync semantics test (testcontextvars.nim) is
## the unit-level baseline; this file proves the load-bearing CLS
## invariants: bindings survive await, concurrent tasks are isolated,
## children inherit but don't leak back.

import unittest2
import ../chronos
import ../chronos/config
import ../chronos/contextvars

when not defined(windows):
  import std/posix
  when chronosEventEngine in ["epoll", "kqueue"]:
    # Signal/process registration (and asyncproc, which this file uses
    # only for spawning a child) exists on the epoll/kqueue engines
    # only — same gate testall.nim applies to testsignal/testproc.
    import ../chronos/asyncproc

{.used.}

contextVar:
  var asyncInt: int = 0
  var asyncStr: string = ""
  var asyncReq: int    # must-bind: no default

suite "contextvars: async propagation":

  test "concurrent tasks with interleaved suspensions each see their own binding":
    # The load-bearing CLS invariant: two tasks bound to different
    # values, forced into lockstep alternation via a future-based
    # handshake (not millisecond-timed sleeps — those are non-
    # deterministic on slow CI and don't prove interleaving order).
    # Each task completes the *other*'s tick to hand off control,
    # then awaits its own next tick. After every await, the resumed
    # task must see its OWN binding, not the other's leftover
    # threadvar. Without capture-at-scheduling + restore-at-fire,
    # taskA's resume after taskB ran would see asyncInt()==200.
    var tickA, tickB: Future[void]
    proc resetTicks() =
      tickA = newFuture[void]("tickA")
      tickB = newFuture[void]("tickB")

    proc taskA(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(100):
        await tickA
        check asyncInt() == 100
        tickB.complete()  # hand off to B
        resetTicks()
        await tickA
        check asyncInt() == 100
        tickB.complete()
        return asyncInt()

    proc taskB(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(200):
        await tickB
        check asyncInt() == 200
        tickA.complete()  # hand off to A
        await tickB
        check asyncInt() == 200
        return asyncInt()

    proc driver(): Future[(int, int)] {.async: (raises: [Exception]).} =
      resetTicks()
      let fa = taskA()
      let fb = taskB()
      tickA.complete()  # kick off A
      let a = await fa
      let b = await fb
      return (a, b)

    let (a, b) = waitFor(driver())
    check a == 100
    check b == 200

  test "multiple value types coexist on same context chain across await":
    # Two distinct contextVars of different value types bound on the
    # same chain; both must remain visible after an await (proving the
    # slot-typed subtype lookup correctly picks each one by type, not
    # by position in the chain).
    proc work(): Future[(int, string)] {.async: (raises: [Exception]).} =
      check asyncInt() == 42
      check asyncStr() == "tracer"
      await sleepAsync(1.milliseconds)
      check asyncInt() == 42
      check asyncStr() == "tracer"
      return (asyncInt(), asyncStr())

    proc driver(): Future[(int, string)] {.async: (raises: [Exception]).} =
      withAsyncInt(42):
        withAsyncStr("tracer"):
          return await work()

    check waitFor(driver()) == (42, "tracer")

  test "binding survives multiple sequential awaits":
    proc work(): Future[int] {.async: (raises: [Exception]).} =
      check asyncInt() == 11
      await sleepAsync(1.milliseconds)
      check asyncInt() == 11
      await sleepAsync(1.milliseconds)
      check asyncInt() == 11
      await sleepAsync(1.milliseconds)
      return asyncInt()

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(11):
        return await work()

    check waitFor(driver()) == 11

  test "child task inherits parent's context at spawn":
    proc child(): Future[int] {.async: (raises: [Exception]).} =
      check asyncInt() == 42     # inherited from parent's binding
      await sleepAsync(1.milliseconds)
      check asyncInt() == 42
      return asyncInt()

    proc parent(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(42):
        return await child()

    check waitFor(parent()) == 42

  test "parent's binding survives spawn-then-await of independent child":
    # The "deferred await" pattern: parent creates a child future
    # (which captures parent's context at spawn time), the parent
    # then does intervening work and finally awaits the child. The
    # parent's bindings must remain its own across the await, even
    # though the child's bindings were briefly current during its
    # iterator pumps. Distinct from `await child()` inline because
    # there are dispatcher returns to the parent between spawn and
    # await.
    proc child(): Future[int] {.async: (raises: [Exception]).} =
      check asyncInt() == 42      # parent's binding inherited
      await sleepAsync(1.milliseconds)
      withAsyncInt(999):           # child rebinds locally
        await sleepAsync(1.milliseconds)
        check asyncInt() == 999
      check asyncInt() == 42      # back to inherited
      return asyncInt()

    proc parent(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(42):
        let f = child()           # spawn
        check asyncInt() == 42
        await sleepAsync(1.milliseconds)  # parent yields, child runs
        check asyncInt() == 42    # parent still sees its own
        let r = await f
        check r == 42
        check asyncInt() == 42    # post-await, parent's binding intact
        return asyncInt()

    check waitFor(parent()) == 42

  test "child's nested binding does not leak back to parent":
    proc child(): Future[void] {.async: (raises: [Exception]).} =
      withAsyncInt(999):
        await sleepAsync(1.milliseconds)
        check asyncInt() == 999
      check asyncInt() == 42    # back to parent's binding

    proc parent(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(42):
        await child()
        return asyncInt()       # parent still sees its own 42

    check waitFor(parent()) == 42

  test "exception across await reverts binding":
    proc work(): Future[void] {.async: (raises: [Exception]).} =
      await sleepAsync(1.milliseconds)
      raise newException(ValueError, "boom across await")

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      try:
        withAsyncInt(77):
          check asyncInt() == 77
          await work()
          check false           # unreachable
      except ValueError:
        discard
      return asyncInt()         # binding reverted

    check waitFor(driver()) == 0

  test "CancelledError across await reverts binding":
    proc longSleep(): Future[void] {.async: (raises: [Exception]).} =
      await sleepAsync(1.seconds)

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      let f = longSleep()
      var observed = -1
      try:
        withAsyncInt(55):
          check asyncInt() == 55
          # Cancel the inner future from a sibling timer so cancellation
          # propagates through our `await f`.
          discard setTimer(Moment.now() + 1.milliseconds,
                           proc(_: pointer) {.gcsafe, raises: [].} =
                             f.cancelSoon())
          await f
          check false           # unreachable — cancel must propagate
      except CancelledError:
        observed = asyncInt()
      check observed == 0       # CancelledError unwound withAsyncInt(55)
      return asyncInt()

    check waitFor(driver()) == 0

  test "CancelledError caught inside withName sees the binding":
    # `withCurrentUser(authed): try: await work()
    # except CancelledError: check currentUser() == authed`. Unlike the
    # test above (where `try/except` is OUTSIDE the binder and the
    # binding has reverted by the time the handler runs), here the
    # handler is INSIDE the binder — the binding must still be visible
    # while the handler executes, before the binder's `finally` runs.
    proc longSleep(): Future[void] {.async: (raises: [Exception]).} =
      await sleepAsync(1.seconds)

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      let f = longSleep()
      var observedInsideHandler = -1
      withAsyncInt(88):
        check asyncInt() == 88
        discard setTimer(Moment.now() + 1.milliseconds,
                         proc(_: pointer) {.gcsafe, raises: [].} =
                           f.cancelSoon())
        try:
          await f
          check false           # unreachable
        except CancelledError:
          observedInsideHandler = asyncInt()   # binder still active
      check observedInsideHandler == 88
      return asyncInt()         # binder reverted on normal exit

    check waitFor(driver()) == 0

suite "contextvars: scheduling-site capture coverage":

  test "callSoon callback fires with the registrant's binding":
    # callSoon is a direct user-facing scheduling API. The callback
    # is run on the next dispatcher tick; without context capture at
    # the AsyncCallback construction site in callSoon(cbproc, data),
    # the callback runs under whatever context the dispatcher last
    # set, losing the registrant's bindings.
    var seenBinding = -1
    var fired = false

    proc cb(udata: pointer) {.gcsafe, raises: [].} =
      seenBinding = asyncInt()
      fired = true

    proc driver(): Future[void] {.async: (raises: [Exception]).} =
      withAsyncInt(789):
        callSoon(cb, nil)
        while not fired:
          await sleepAsync(1.milliseconds)

    waitFor(driver())
    check seenBinding == 789

  test "sleepAsync callback fires with the registrant's binding":
    # sleepAsync goes through setTimer, which constructs an AsyncCallback
    # via userCallback — the timer's completion handler fires under the
    # binding the sleeper had at sleepAsync invocation. Exercised
    # implicitly by every async test that awaits sleepAsync, but pinned
    # explicitly here as a regression guard against future drift in
    # setTimer's construction site.
    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(456):
        await sleepAsync(1.milliseconds)
        return asyncInt()
    check waitFor(driver()) == 456

  test "internalCallTick is context-blind (internal trampoline)":
    # `internalCallTick` is the dispatcher's internal "after OS queue
    # processing" hook (used by `checktick`, `stepsAsync` etc. — never
    # by user code that reads contextVars). Per the two-constructor
    # discipline, internal scheduling sites use `bareCallback` (no
    # context capture). A callback scheduled via `internalCallTick(cb)`
    # from inside `withAsyncInt(123)` must NOT see asyncInt() == 123 —
    # it sees the default (0), because no context was captured.
    var seenBinding = -1
    var fired = false

    proc cb(udata: pointer) {.gcsafe, raises: [].} =
      seenBinding = asyncInt()
      fired = true

    proc driver(): Future[void] {.async: (raises: [Exception]).} =
      withAsyncInt(123):
        internalCallTick(cb, nil)
        while not fired:
          await sleepAsync(1.milliseconds)

    waitFor(driver())
    check seenBinding == 0

  test "callIdle callback fires with the registrant's binding":
    # `callIdle(cbproc, data)` wraps via `userCallback`; the idle
    # callback fires under the registrant's context.
    var seenBinding = -1
    var fired = false

    proc idleCb(udata: pointer) {.gcsafe, raises: [].} =
      seenBinding = asyncInt()
      fired = true

    proc driver(): Future[void] {.async: (raises: [Exception]).} =
      withAsyncInt(321):
        callIdle(idleCb, nil)
        while not fired:
          await sleepAsync(1.milliseconds)

    waitFor(driver())
    check seenBinding == 321

  when not defined(windows):
    # `addReader`/`addWriter`/`addSignal2`/`addProcess2` on arbitrary
    # fds/pids are POSIX-selector APIs; on Windows the equivalents go
    # through IOCP paths with different registration surfaces (and the
    # signal/process waitable path is the documented empty-context gap).

    test "addReader callback fires with the registrant's binding":
      # Register an fd-readiness callback inside a `withName` block, fire
      # it via write, verify the callback sees the binding. Exercises
      # `addReader2`'s `userCallback` wiring end-to-end.
      var seenBinding = -1
      var fired = false
      let (rfd, wfd) = createAsyncPipe()
      proc onReadable(udata: pointer) {.gcsafe, raises: [].} =
        seenBinding = asyncInt()
        fired = true

      proc driver(): Future[void] {.async: (raises: [Exception]).} =
        withAsyncInt(654):
          register(rfd)
          addReader(rfd, onReadable)
          # Poke the write end to make the read end readable.
          let buf = "x"
          discard posix.write(cint(wfd), unsafeAddr buf[0], 1)
          while not fired:
            await sleepAsync(1.milliseconds)
          removeReader(rfd)
        closeSocket(rfd)
        closeSocket(wfd)
      waitFor(driver())
      check seenBinding == 654

    test "addWriter callback fires with the registrant's binding":
      # Mirror of the addReader test on `addWriter2`'s `userCallback`
      # wiring: an empty pipe's write end is immediately writable, so
      # the callback fires on the next poll tick.
      var seenBinding = -1
      var fired = false
      let (rfd, wfd) = createAsyncPipe()
      proc onWritable(udata: pointer) {.gcsafe, raises: [].} =
        seenBinding = asyncInt()
        fired = true

      proc driver(): Future[void] {.async: (raises: [Exception]).} =
        withAsyncInt(655):
          register(wfd)
          addWriter(wfd, onWritable)
          while not fired:
            await sleepAsync(1.milliseconds)
          removeWriter(wfd)
        closeSocket(rfd)
        closeSocket(wfd)
      waitFor(driver())
      check seenBinding == 655

    when chronosEventEngine in ["epoll", "kqueue"]:
      # Signal/process registration exists on the epoll/kqueue engines
      # only - same gate testall.nim applies to testsignal/testproc.
      test "addSignal2 handler fires with the registrant's binding":
        # `addSignal2` wraps the handler via `userCallback` (epoll/kqueue
        # paths); the handler must observe the binding current at
        # registration, not whatever the dispatcher last set.
        var seenBinding = -1
        var sigFd: SignalHandle
        let handlerFut = newFuture[void]("ctx.signal.handler")
        proc signalHandler(udata: pointer) {.gcsafe.} =
          seenBinding = asyncInt()
          let res = removeSignal2(sigFd)
          if res.isErr():
            handlerFut.fail(newException(ValueError, osErrorMsg(res.error())))
          else:
            handlerFut.complete()

        proc driver(): Future[void] {.async: (raises: [Exception]).} =
          withAsyncInt(456):
            sigFd =
              block:
                let res = addSignal2(SIGUSR1, signalHandler)
                if res.isErr():
                  raiseAssert osErrorMsg(res.error())
                res.get()
            discard posix.kill(posix.getpid(), cint(SIGUSR1))
            await handlerFut.wait(5.seconds)
        waitFor(driver())
        check seenBinding == 456

      test "addProcess2 handler fires with the registrant's binding":
        # `addProcess2` wraps the handler via `userCallback` (pidfd/kqueue
        # paths); the exit handler must observe the registrant's binding.
        var seenBinding = -1
        var pidFd: ProcessHandle
        let handlerFut = newFuture[void]("ctx.process.handler")
        var process: AsyncProcessRef
        proc processHandler(udata: pointer) {.gcsafe.} =
          seenBinding = asyncInt()
          let res = removeProcess2(pidFd)
          if res.isErr():
            handlerFut.fail(newException(ValueError, osErrorMsg(res.error())))
          else:
            handlerFut.complete()

        proc driver(): Future[void] {.async: (raises: [Exception]).} =
          process = await startProcess("sleep 0.3",
                                       options = {AsyncProcessOption.EvalCommand})
          try:
            withAsyncInt(789):
              pidFd =
                block:
                  let res = addProcess2(process.pid(), processHandler)
                  if res.isErr():
                    raiseAssert osErrorMsg(res.error())
                  res.get()
              await handlerFut.wait(5.seconds)
          finally:
            await process.closeWait()
        waitFor(driver())
        check seenBinding == 789

  test "race() resolver fires with the awaiter's binding":
    # Combinators propagate context to their continuations.
    # `race(fa, fb)` installs callbacks on each future; the resolver
    # fires when the first completes, then the awaiter
    # of `race()`'s returned future resumes — under the awaiter's
    # context, not whichever child task completed first.
    proc child(value: int, delayMs: int): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(value):
        await sleepAsync(delayMs.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(111):
        let fa = child(222, 1)
        let fb = child(333, 50)
        discard await race(FutureBase(fa), FutureBase(fb))
        # After race resolves and we resume, our binding (111) must
        # still be current — not 222 or 333 from the children.
        let observed = asyncInt()
        # Drain the loser so it doesn't leak into testutils' pending
        # check (it's still pending when race returns the winner).
        await fb.cancelAndWait()
        return observed

    check waitFor(driver()) == 111

  test "allFutures() continuation fires with the awaiter's binding":
    # `allFutures(fa, fb)` waits for both; the awaiter's binding must
    # be visible after the combinator resolves, not one of the child
    # task's bindings.
    proc child(value: int): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(222):
        let fa = child(444)
        let fb = child(555)
        await allFutures(fa, fb)
        return asyncInt()

    check waitFor(driver()) == 222

  test "wait(duration) resumes the awaiter under its own binding":
    # `wait` installs an internal timer + completion callback pair; the
    # awaiter must resume under its own binding, not the child's, and
    # not lose it to wait's internal scheduling.
    proc child(value: int): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(31):
        check (await child(32).wait(1.seconds)) == 32
        return asyncInt()

    check waitFor(driver()) == 31

  test "wait(deadline future) resumes the awaiter under its own binding":
    # The deadline-future variant routes through waitUntilImpl, a
    # separate internal path from the duration variant.
    proc child(value: int): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(36):
        let deadline = sleepAsync(1.seconds)
        check (await child(37).wait(deadline)) == 37
        await deadline.cancelAndWait()
        return asyncInt()

    check waitFor(driver()) == 36

  test "withTimeout() resumes the awaiter under its own binding":
    proc child(value: int): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(41):
        let fut = child(42)
        check (await fut.withTimeout(1.seconds)) == true
        check fut.read() == 42
        return asyncInt()

    check waitFor(driver()) == 41

  test "`or` resumes the awaiter under its own binding":
    proc child(value: int, delayMs: int): Future[void] {.async: (raises: [Exception]).} =
      withAsyncInt(value):
        await sleepAsync(delayMs.milliseconds)

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(51):
        let fa = child(52, 1)
        let fb = child(53, 50)
        await fa or fb
        let observed = asyncInt()
        # Drain the loser so it doesn't trip testutils' pending check.
        await fb.cancelAndWait()
        return observed

    check waitFor(driver()) == 51

  test "join() resumes the awaiter under its own binding":
    proc child(value: int): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(value):
        await sleepAsync(1.milliseconds)
        return value

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncInt(61):
        let fut = child(62)
        await fut.join()
        check fut.read() == 62
        return asyncInt()

    check waitFor(driver()) == 61

  test "closeHandle aftercb fires with the registrant's binding":
    # On Linux, `closeHandle` forwards to `closeSocket`; on Windows it
    # has its own IOCP path. Tested separately from `closeSocket` so a
    # future divergence between the two doesn't silently lose context
    # propagation on either.
    var seenBinding = -1
    var fired = false
    let (rfd, wfd) = createAsyncPipe()
    proc cb(udata: pointer) {.gcsafe, raises: [].} =
      seenBinding = asyncInt()
      fired = true
    proc driver(): Future[void] {.async: (raises: [Exception]).} =
      withAsyncInt(987):
        closeHandle(rfd, cb)
        closeHandle(wfd)
        while not fired:
          await sleepAsync(1.milliseconds)
    waitFor(driver())
    check seenBinding == 987

  test "closeSocket aftercb fires with the registrant's binding":
    # `closeSocket(fd, aftercb)` schedules `aftercb` after the close.
    # The scheduling site uses `userCallback` so the callback fires
    # under the context bound at close-call time. Regression guard
    # against drift to `bareCallback` (which would drop the
    # caller's context).
    var seenBinding = -1
    var fired = false
    let (rfd, wfd) = createAsyncPipe()
    proc cb(udata: pointer) {.gcsafe, raises: [].} =
      seenBinding = asyncInt()
      fired = true
    proc driver(): Future[void] {.async: (raises: [Exception]).} =
      withAsyncInt(321):
        closeSocket(rfd, cb)
        closeSocket(wfd)
        while not fired:
          await sleepAsync(1.milliseconds)
    waitFor(driver())
    check seenBinding == 321

suite "contextvars: bridging independent callbacks":

  test "currentContext()/withContext() bridges independent callbacks":
    # An enter hook and a separately-fired exit hook (no await or
    # shared call stack between them) are not a single logical task,
    # so no binder can span them -
    # the dispatcher restores the context it captured at each
    # callback's own scheduling time around every invocation
    # (`fireWithContext` in chronos/internal/asyncengine.nim). The
    # documented tool for this shape: capture with currentContext() in
    # the enter hook, restore with withContext() in the exit hook. The
    # snapshot is a value the caller carries itself (not a chain
    # mutation the dispatcher unwinds at fire time), so it is
    # unaffected by fireWithContext's restore around the enter
    # callback's own invocation and remains valid for the later,
    # separate exit callback to restore explicitly.
    var snapshot: AsyncContext
    var enterRan = false
    var exitObserved = -1

    proc enterCb(udata: pointer) {.gcsafe, raises: [].} =
      withAsyncInt(42):
        snapshot = currentContext()
      enterRan = true

    proc exitCb(udata: pointer) {.gcsafe, raises: [].} =
      withContext(snapshot):
        exitObserved = asyncInt()

    callSoon(enterCb, nil)
    poll()
    check enterRan

    callSoon(exitCb, nil)
    poll()
    check exitObserved == 42

suite "contextvars: cancelCallback capture":

  test "cancelCallback observes the registrant's binding, not the canceller's":
    # `cancelCallback=` is set inside binding "owner"; `tryCancel` is
    # invoked synchronously from inside binding "canceller". Per the
    # capture/restore discipline every other user-facing callback
    # follows, the handler must see "owner" (registration-time), not
    # "canceller" (the ambient context when `tryCancel` happened to run).
    var seenBinding = ""
    var fired = false

    let fut = newFuture[void]("owner-future")
    withAsyncStr("owner"):
      fut.cancelCallback = proc(_: pointer) {.gcsafe, raises: [].} =
        seenBinding = asyncStr()
        fired = true

    withAsyncStr("canceller"):
      discard tryCancel(fut)

    check fired
    check seenBinding == "owner"

  test "cancelCallback observes the registrant's binding through cancelSoon's checktick retry":
    # `FutureFlag.OwnCancelSchedule` means `tryCancel` won't auto-cancel
    # the future on the owner's behalf - the owner's `cancelCallback`
    # must do it. The callback here defers actual cancellation to its
    # second invocation, so the first call (synchronous, from
    # `cancelSoon`'s initial `tryCancel`) reports "not yet cancelled",
    # forcing `internalCallTick(checktick)`. `checktick` is a
    # context-blind internal trampoline (`bareCallback`, no
    # capture) - so its downstream `tryCancel` call runs with no
    # ambient context. The registrant's captured "owner" binding must
    # still be what the callback observes on both invocations.
    var observed: seq[string]

    let fut = newFuture[void]("owner-future-checktick",
                              {FutureFlag.OwnCancelSchedule})

    proc onCancel(_: pointer) {.gcsafe, raises: [].} =
      observed.add asyncStr()
      if observed.len >= 2:
        fut.cancelAndSchedule()

    withAsyncStr("owner"):
      fut.cancelCallback = onCancel

    proc driver(): Future[void] {.async: (raises: [Exception]).} =
      withAsyncStr("canceller"):
        cancelSoon(fut)
        while not fut.finished():
          await sleepAsync(1.milliseconds)

    waitFor(driver())
    check observed == @["owner", "owner"]

  test "cancelCallback with no contextvars anywhere still cancels (nil context)":
    # Default-path regression: a future whose cancelCallback was set
    # with no binder in scope anywhere must still cancel cleanly - the
    # captured (nil) context must round-trip through the save/restore
    # without incident.
    var fired = false

    let fut = newFuture[void]("no-context-future")
    fut.cancelCallback = proc(_: pointer) {.gcsafe, raises: [].} =
      fired = true

    check tryCancel(fut)
    check fired
    check fut.cancelled()

  test "cancelCallback fast arm fires cleanly while an unrelated task is parked mid-binder elsewhere":
    # `fireCancelCallback`'s fast arm (identity `withRestoredContext`)
    # must observe exactly its own captured context, undisturbed by an
    # unrelated task parked mid-`await` inside its own binder elsewhere
    # on the same dispatcher - and must leave the ambient context clean
    # for that task's eventual resume. The parked task's own suspend
    # already restores ambient context to nil before returning here;
    # this test verifies that the fast path does not reintroduce a leak
    # by observing or clobbering that restored nil state.
    let parkedWaiter = newFuture[void]("parked-waiter")
    var parkedObserved = -2

    proc parked(): Future[void] {.async: (raises: [Exception]).} =
      withAsyncInt(777):
        await parkedWaiter          # suspends INSIDE the binder
        parkedObserved = asyncInt()

    let parkedFut = parked()        # runs synchronously to the await;
                                     # suspended mid-binder, ambient
                                     # context already restored to nil
                                     # on return
    check asyncInt() == 0           # confirms no leak from `parked`'s entry

    var fired = false
    let fut = newFuture[void]("cancel-future")
    fut.cancelCallback = proc(_: pointer) {.gcsafe, raises: [].} =
      check asyncInt() == 0         # own captured (nil) context, not 777
      fired = true

    check tryCancel(fut)            # fires while `parked` sits suspended
    check fired
    check fut.cancelled()
    check asyncInt() == 0           # still clean after the cancel fires

    parkedWaiter.complete()
    waitFor parkedFut
    check parkedObserved == 777     # parked's own binding, undisturbed

suite "contextvars: fast-path pins":
  # These tests pin the observable contract `withRestoredContext`/
  # `fireWithContext` must hold across both the identity fast arm (no
  # writes to `currentAsyncContext`) and the slow arm (write + restore).
  # They are regression guards, not drivers of a behavior change - the
  # dispatcher already restores context correctly via the identity
  # short-circuit on the fast arm and unconditional save/restore on the
  # slow arm.

  test "interleaved fast/slow-arm callbacks in one poll batch each observe their own context":
    # `withRestoredContext` takes the identity fast arm when the
    # captured context already equals the ambient context at fire time
    # (the common nil/nil case - no bindings anywhere), and the slow
    # arm (write + restore) otherwise. Schedule several callbacks in a
    # single batch, alternating callbacks captured with no ambient
    # binder (fast arm) and callbacks captured from inside a binder
    # (slow arm), so consecutive callbacks flip the branch back and
    # forth. Each must observe exactly its own captured value
    # regardless of which arm fired the callback immediately before it.
    var seen: seq[int]

    proc recordCb(udata: pointer) {.gcsafe, raises: [].} =
      seen.add asyncInt()

    callSoon(recordCb, nil)          # nil capture -> fast arm (nil == nil)
    withAsyncInt(11):
      callSoon(recordCb, nil)        # 11 capture  -> slow arm
    callSoon(recordCb, nil)          # nil capture -> fast arm
    withAsyncInt(22):
      callSoon(recordCb, nil)        # 22 capture  -> slow arm
    withAsyncInt(33):
      callSoon(recordCb, nil)        # 33 capture  -> slow arm
    callSoon(recordCb, nil)          # nil capture -> fast arm

    poll()
    check seen == @[0, 11, 0, 22, 33, 0]

  test "bind-and-raise on the fast arm leaves the ambient context clean after the batch":
    # Fast-arm coverage for exit class 2 (raise). The callback below is
    # scheduled with no ambient binder, so its captured (nil) context
    # equals the ambient (nil) context at fire
    # time - `withRestoredContext`'s identity fast arm, which runs
    # `body` directly with no `try`/`finally` of its own. `CallbackFunc`
    # is `raises: []`, so the raiser must be a `Defect` to escape the
    # callback; `contextBindSlot`'s own `finally` still runs on that
    # unwind (that is exit class 2's mechanism, independent of which
    # arm fired the callback), so the binding must be gone by the time
    # `poll()` returns even though the fast arm itself never wrote or
    # restored `currentAsyncContext`. Verified through the public
    # `asyncInt()` reader, not the internal `chronosDebug` batch assert
    # - that assert is a separate, independent net (only compiled under
    # `-d:chronosDebug`), not the oracle for this test.
    proc raiser(udata: pointer) {.gcsafe, raises: [].} =
      withAsyncInt(999):
        doAssert false, "contextvars: intentional Defect to " &
                         "exercise the fast-arm raise path"

    callSoon(raiser, nil)
    var caught = false
    try:
      poll()
    except Defect:
      caught = true
    check caught
    check asyncInt() == 0

  test "bind-and-raise on the slow arm restores the prior ambient context after the batch (fireWithContext)":
    # Slow-arm counterpart to the fast-arm test above. Capture the
    # callback's context under one binding (111), then fire it while a
    # DIFFERENT binding (222) is ambient - the captured and ambient
    # contexts differ, so `withRestoredContext` must take the slow arm
    # (write the captured context in, `try`/`finally` restore the prior
    # one back out) rather than the identity fast arm. The callback body
    # itself asserts `asyncInt() == 111` before raising - reaching that
    # check is proof the slow arm's write actually ran, not just an
    # assumption about which branch fired. `CallbackFunc` is
    # `raises: []`, so the raiser must escape as a `Defect`; the
    # `except` sits INSIDE the `withAsyncInt(222)` block (rather than
    # outside it) so the assertion below observes the state immediately
    # after `withRestoredContext`'s own `finally` runs, before the
    # outer `withAsyncInt(222)` binder's own `finally` unwinds further.
    proc raiser(udata: pointer) {.gcsafe, raises: [].} =
      check asyncInt() == 111       # proves the slow arm's write executed
      doAssert false, "contextvars: intentional Defect to " &
                       "exercise the slow-arm restore path (fireWithContext)"

    withAsyncInt(111):
      callSoon(raiser, nil)         # captured context = 111

    withAsyncInt(222):               # ambient at fire time = 222 != 111
      var caught = false
      try:
        poll()
      except Defect:
        caught = true
      check caught
      # `withRestoredContext`'s `finally` must restore the ambient
      # context to what it was before the slow arm's write (222), not
      # leave it at the callback's captured value (111).
      check asyncInt() == 222
    check asyncInt() == 0

  test "bind-and-raise on the slow arm restores the prior ambient context after cancellation (fireCancelCallback)":
    # Same slow-arm restore contract as above, through the cancel-
    # callback fire site (`fireCancelCallback` in
    # `chronos/internal/asyncfutures.nim`) rather than the regular
    # callback fire site (`fireWithContext`). A `cancelCallback`
    # registered under one binding (333), fired via `tryCancel` while a
    # DIFFERENT binding (444) is ambient, forces the same
    # write+try/finally slow arm in `withRestoredContext`.
    let fut = newFuture[void]("slow-arm-cancel")
    proc raiserCancel(_: pointer) {.gcsafe, raises: [].} =
      check asyncInt() == 333       # proves the slow arm's write executed
      doAssert false, "contextvars: intentional Defect to " &
                       "exercise the slow-arm restore path (fireCancelCallback)"

    withAsyncInt(333):
      fut.cancelCallback = raiserCancel   # captured context = 333

    withAsyncInt(444):               # ambient at fire time = 444 != 333
      var caught = false
      try:
        discard tryCancel(fut)
      except Defect:
        caught = true
      check caught
      # Same restore contract as the fireWithContext test above, pinned
      # through the cancel-callback fire site instead.
      check asyncInt() == 444
    check asyncInt() == 0

  test "nil-captured resume through a suspended binder leaves the ambient context clean for a later same-batch callback":
    # `internalContinue`'s resume must restore `currentAsyncContext`
    # even when the resumed slice suspends AGAIN inside a binder before
    # returning control to the dispatcher (an iterator `yield` inside a
    # `withName` block is a plain return - `contextBindSlot`'s `finally`
    # does not run for it). Without that restore, the OUTER fire's fast
    # arm (identity nil == nil) would leave the threadvar pointing at
    # the binder's node for every callback still queued behind it in
    # the same batch. `futureContinue`'s own unconditional save/restore
    # is the load-bearing net; this test pins the observable end-to-end
    # behavior rather than the mechanism.
    let outerWaiter = newFuture[void]("leak-repro.outer")
    let innerWaiter = newFuture[void]("leak-repro.inner")
    var innerObserved = -1
    var laterSeenBinding = -1
    var laterFired = false

    proc leaky(): Future[void] {.async: (raises: [Exception]).} =
      await outerWaiter               # captured with nil ambient context
      withAsyncInt(999):
        await innerWaiter             # suspends INSIDE the binder (class 3)
        innerObserved = asyncInt()

    proc laterCb(udata: pointer) {.gcsafe, raises: [].} =
      laterSeenBinding = asyncInt()
      laterFired = true

    let fut = leaky()                 # synchronous run to `await outerWaiter`
    outerWaiter.complete()            # queues leaky's resume (nil-context capture)
    callSoon(laterCb, nil)            # queued behind the resume, same batch
    poll()

    check laterFired
    check laterSeenBinding == 0       # not leaked from leaky's still-open binder

    innerWaiter.complete()
    waitFor fut
    check innerObserved == 999
    check fut.finished()

  test "await inside withContext survives suspension and leaves ambient restored for a later same-batch callback":
    # Same suspend-hazard as the `withName` pin above, but through the
    # PUBLIC `currentContext()`/`withContext()` bridge instead of the
    # macro-generated binder. `withContext`'s body can itself suspend
    # mid-block (an `await` inside it is a plain iterator return, same
    # as a `yield` inside `withName` - `withContext`'s own `finally`
    # does not run for it), so the same class of hazard applies:
    # without `futureContinue`'s unconditional save/restore on resume,
    # the OUTER fire's fast arm would leave the threadvar pointing at
    # `withContext`'s installed chain for every callback still queued
    # behind it in the same batch.
    var boundCtx: AsyncContext
    withAsyncInt(999):
      boundCtx = currentContext()

    let outerWaiter = newFuture[void]("wc-leak-repro.outer")
    let innerWaiter = newFuture[void]("wc-leak-repro.inner")
    var innerObserved = -1
    var laterSeenBinding = -1
    var laterFired = false

    proc leaky(): Future[void] {.async: (raises: [Exception]).} =
      await outerWaiter               # captured with nil ambient context
      withContext(boundCtx):
        await innerWaiter             # suspends INSIDE withContext's body
        innerObserved = asyncInt()

    proc laterCb(udata: pointer) {.gcsafe, raises: [].} =
      laterSeenBinding = asyncInt()
      laterFired = true

    let fut = leaky()                 # synchronous run to `await outerWaiter`
    outerWaiter.complete()            # queues leaky's resume (nil-context capture)
    callSoon(laterCb, nil)            # queued behind the resume, same batch
    poll()

    check laterFired
    check laterSeenBinding == 0       # not leaked from leaky's still-open withContext

    innerWaiter.complete()
    waitFor fut
    check innerObserved == 999        # the withContext binding survived the suspend
    check fut.finished()

suite "contextvars: scheduling scenario pins":
  # Each test here pins currently-correct behavior against a scenario
  # not exercised by the earlier suites (nested reentrancy, cross-thread
  # isolation, capture on a finished future, and the stream-server
  # transitive-fire-site coverage). Green from the start by design -
  # these are regression pins, not drivers of a behavior change.

  test "nested waitFor inside a running callback observes its own binding and leaves the outer callback's context intact":
    # Reentrancy x fast path. `waitFor` from inside a plain (non-async)
    # callback is legal in default builds - `chronosStrictReentrancy`
    # (which would gate reentrant draining) defaults on only under
    # `chronosPreviewV5`. Under `chronosPreviewV5` the nested `waitFor`
    # itself is illegal (see the strict-mode pin below), so this scenario
    # - which depends on the nested drain succeeding - only applies to
    # default (non-strict) builds. `outerCb` is scheduled with no ambient
    # binder, so its capture (nil) equals ambient at fire time -
    # `withRestoredContext`'s identity fast arm fires it. From inside that
    # fast-armed frame it binds its own contextVar, then calls `waitFor` on
    # a small async proc that binds the SAME var to a different value;
    # `waitFor` pumps the dispatcher reentrantly (a nested `poll()` loop)
    # until the inner future resolves. Three things must hold: the inner
    # work sees its own binding, not the outer's; the outer's ambient
    # binding is exactly restored once the nested `waitFor` returns control
    # (not left at the inner value, not wiped to nil); and a callback
    # queued behind `outerCb` in the same top-level batch - which may fire
    # either during the nested reentrant drain or after `outerCb` returns,
    # depending on queue interleaving - observes an empty context either
    # way, undisturbed by the reentrancy.
    when chronosStrictReentrancy:
      skip()
    else:
      var innerObserved = -1
      var outerAfterNested = -1
      var outerFired = false
      var laterSeenBinding = -1
      var laterFired = false

      proc innerWork(): Future[int] {.async: (raises: [CancelledError]).} =
        withAsyncInt(999):
          await sleepAsync(1.milliseconds)
          return asyncInt()

      proc laterCb(udata: pointer) {.gcsafe, raises: [].} =
        laterSeenBinding = asyncInt()
        laterFired = true

      proc outerCb(udata: pointer) {.gcsafe, raises: [].} =
        withAsyncInt(500):
          check asyncInt() == 500
          try:
            innerObserved = waitFor(innerWork())
          except CancelledError:
            discard
          outerAfterNested = asyncInt()
        outerFired = true

      callSoon(outerCb, nil)   # nil capture == nil ambient at fire -> fast arm
      callSoon(laterCb, nil)   # queued behind outerCb, same top-level batch
      poll()

      check outerFired
      check innerObserved == 999
      check outerAfterNested == 500
      check laterFired
      check laterSeenBinding == 0

  test "nested waitFor inside a running callback raises under chronosStrictReentrancy, leaving the outer callback's context intact":
    # Strict-mode counterpart to the scenario above. `chronosPreviewV5`
    # defaults `chronosStrictReentrancy` on, and `preparePoll`
    # (asyncengine.nim) asserts `not loop.inEventLoop` before a nested
    # `poll`/`runForever`/`waitFor` is allowed to proceed - so the nested
    # `waitFor` below must raise `AssertionDefect` instead of draining.
    # This pins that the assert fires deterministically from inside a
    # plain callback (not just the compile-time-detectable `{.async.}`
    # case already covered by testmacro.nim), and - the contextvars-
    # specific half of the pin - that the outer callback's ambient
    # binding survives the raise untouched: the assert fires in
    # `preparePoll` before any context is touched, so `withAsyncInt`'s
    # binding for 500 must still read back exactly as bound.
    when chronosStrictReentrancy:
      var outerAfterRaise = -1
      var outerFired = false

      proc innerWork(): Future[int] {.async: (raises: [CancelledError]).} =
        withAsyncInt(999):
          await sleepAsync(1.milliseconds)
          return asyncInt()

      proc outerCb(udata: pointer) {.gcsafe, raises: [].} =
        withAsyncInt(500):
          check asyncInt() == 500
          expect(Defect):
            discard waitFor(innerWork())
          outerAfterRaise = asyncInt()
        outerFired = true

      callSoon(outerCb, nil)   # nil capture == nil ambient at fire -> fast arm
      poll()

      check outerFired
      check outerAfterRaise == 500
    else:
      skip()

  test "two threads with independent dispatchers never observe each other's contextVar binding":
    # `currentAsyncContext` is `{.threadvar.}` (chronos/futures.nim), and
    # each OS thread gets its own dispatcher (also threadvar-based) the
    # first time it touches the event loop - so two threads binding the
    # SAME contextVar to different values and each running its own async
    # work through its own `waitFor` must never see the other's binding.
    # Pattern follows testsoon.nim's cross-thread `createThread`/
    # `joinThreads` and testmpsc.nim's multi-producer thread spawn; unlike
    # testsoon's cross-thread `callSoon`, these two dispatchers never
    # communicate - each is pristine and fully independent.
    type ThreadArg = object
      boundValue: int
      resultPtr: ptr int
      readyPtr: ptr bool

    proc threadProc(arg: ThreadArg) {.thread, nimcall.} =
      withAsyncInt(arg.boundValue):
        proc work(): Future[int] {.async: (raises: [CancelledError]).} =
          await sleepAsync(1.milliseconds)
          return asyncInt()
        arg.resultPtr[] = waitFor(work())
      arg.readyPtr[] = true

    var resultA, resultB: int
    var readyA, readyB: bool
    var threadA: Thread[ThreadArg]
    var threadB: Thread[ThreadArg]
    createThread(threadA, threadProc,
                 ThreadArg(boundValue: 111, resultPtr: addr resultA,
                           readyPtr: addr readyA))
    createThread(threadB, threadProc,
                 ThreadArg(boundValue: 222, resultPtr: addr resultB,
                           readyPtr: addr readyB))
    joinThreads(threadA, threadB)

    check readyA
    check readyB
    check resultA == 111
    check resultB == 222

  test "cross-thread callSoon() fires with an empty context and leaves the origin thread's own binding undisturbed":
    # `DispatcherHandle.callSoon` (`chronos/internal/asyncengine.nim`,
    # exercised cross-thread by testsoon.nim's "cross-thread callSoon()
    # test") posts through a shared MPSC queue when the poster is not
    # the target dispatcher's own thread, and is drained on the
    # ORIGIN thread via `bareCallback` (`processThreadCallbacks`) - no
    # context capture, since the posting thread's binding chain is
    # thread-local, garbage-collected memory that cannot cross threads.
    # Bind a contextVar on the origin thread (whose dispatcher receives
    # the post and whose `poll()` fires it), spawn a second thread that
    # posts a callback back through that dispatcher's `DispatcherHandle`,
    # and confirm two things once the origin thread's `poll()` fires it:
    # the callback observes the DEFAULT (unbound) value, not the origin
    # thread's own ambient binding; and the origin thread's own binding
    # is unchanged afterward - the empty-context fire must not disturb
    # the ambient state it fired into.
    type CrossThreadResult = object
      seenBinding: int
      fired: bool

    proc crossThreadCb(udata: pointer) {.nimcall, gcsafe, raises: [].} =
      let r = cast[ptr CrossThreadResult](udata)
      r.seenBinding = asyncInt()
      r.fired = true

    type ThreadArg = (DispatcherHandle, ptr CrossThreadResult)
    proc threadProc(arg: ThreadArg) {.thread, nimcall.} =
      callSoon(arg[0], crossThreadCb, cast[pointer](arg[1]))

    var res: CrossThreadResult
    let disp = getThreadDispatcher()

    withAsyncInt(555):
      var thread: Thread[ThreadArg]
      createThread(thread, threadProc, (disp.handle(), addr res))
      poll()

      check res.fired
      check res.seenBinding == 0     # DEFAULT - not leaked from the origin's 555
      check asyncInt() == 555        # origin thread's own binding undisturbed
      joinThreads(thread)

    check asyncInt() == 0

  test "addCallback on an already-finished future captures the caller's binding, not the completer's":
    # `addCallback` on a future that is already finished takes the
    # immediate-dispatch branch (`callSoon(cb, udata)`, asyncfutures.nim)
    # rather than storing into `internalCallback`/`internalCallbacks` - the
    # completer's binding at completion time is irrelevant; only the
    # caller's ambient binding when `addCallback` itself is invoked is
    # captured (`callSoon` -> `userCallback`). Complete the future under
    # one binding, then add a callback to the already-finished future from
    # a DIFFERENT binding - the callback must observe the adder's, not the
    # completer's.
    var seenBinding = -1
    var fired = false

    let fut = newFuture[void]("already-finished")
    withAsyncInt(111):
      fut.complete()               # completed under binding 111

    check fut.finished()

    withAsyncInt(222):
      fut.addCallback(proc(udata: pointer) {.gcsafe, raises: [].} =
        seenBinding = asyncInt()
        fired = true
      )

    poll()
    check fired
    check seenBinding == 222       # the adder's binding, not the completer's

  test "stream server handler observes the context bound at start()-time registration, not creation-time or connection-time":
    # Server handlers are `asyncSpawn`ed from inside an already-fired
    # `fireWithContext` frame - the accept-loop's own callback - so the
    # handler inherits whatever
    # context that frame captured. Traced empirically: `createStreamServer`
    # only builds the `StreamServer` object (no registration happens
    # there); `start()` -> `start2()` -> `resumeAccept()` calls
    # `addReader2(server.sock, acceptCb, ...)`, which captures the ambient
    # context via `userCallback` at THAT call - i.e. at `start()` time, not
    # `createStreamServer()` time. `acceptCb` (the fired accept-ready
    # callback) then calls `asyncSpawn server.function(server, ntransp)`
    # synchronously inside its own already-restored frame - a transitive
    # fire site, not a new capture site. So the handler must observe the
    # binding active when `start()` was called, not the binding active at
    # `createStreamServer()` (creation-time) nor at `connect()`
    # (connection-time) - both of which are deliberately different values
    # here to make a wrong capture site observable.
    var seenBinding = -1
    var handlerFired = false
    let handlerDone = newFuture[void]("stream-handler-done")

    proc handler(server: StreamServer,
                 transp: StreamTransport) {.async: (raises: []).} =
      seenBinding = asyncInt()
      handlerFired = true
      transp.close()
      handlerDone.complete()

    let ta = initTAddress("127.0.0.1:0")
    var server: StreamServer
    withAsyncInt(111):
      server = createStreamServer(ta, handler, {ReuseAddr})  # creation-time: 111

    withAsyncInt(222):
      server.start()                                         # registration-time: 222

    proc driver(): Future[void] {.async: (raises: [Exception]).} =
      withAsyncInt(333):                                     # connection-time: 333
        var transp = await connect(server.localAddress())
        await handlerDone.wait(5.seconds)
        transp.close()

    waitFor(driver())

    check handlerFired
    check seenBinding == 222       # start()-time registration binding

    server.stop()
    server.close()
    waitFor(server.join())

suite "contextvars: must-bind async propagation":

  test "must-bind binding propagates across await exactly like a defaulted var":
    # Same capture-at-scheduling/restore-at-fire machinery as
    # `asyncInt`/`asyncStr` above — must-bind arms use the identical
    # generated binder and the identical dispatcher plumbing, only the
    # READER differs (raise vs. default on a miss). This test pins
    # that the propagation half of the contract is unaffected: bind
    # before an `await`, read the same value after it resumes.
    proc work(): Future[int] {.async: (raises: [Exception]).} =
      check asyncReq() == 17
      await sleepAsync(1.milliseconds)
      check asyncReq() == 17
      return asyncReq()

    proc driver(): Future[int] {.async: (raises: [Exception]).} =
      withAsyncReq(17):
        return await work()

    check waitFor(driver()) == 17

  test "must-bind read with no binder anywhere, including across await, raises":
    proc work(): Future[void] {.async: (raises: [Exception]).} =
      await sleepAsync(1.milliseconds)
      expect(UnboundContextVarDefect):
        discard asyncReq()

    waitFor(work())

