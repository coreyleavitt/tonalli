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
    # docs §Test plan. Two distinct contextVars of different value
    # types bound on the same chain; both must remain visible after
    # an await (proving the slot-typed subtype lookup correctly
    # picks each one by type, not by position in the chain).
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
    # docs §Test plan: `withCurrentUser(authed): try: await work()
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
    # discipline, internal scheduling sites use `internalCallback` (no
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
    # docs §Test plan: each user-facing scheduler captures correctly.
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
    # signal/process waitable path is the documented empty-context gap,
    # docs §Migration / compatibility).

    test "addReader callback fires with the registrant's binding":
      # Realistic use case (docs §Test plan): register an fd-readiness
      # callback inside a `withName` block, fire it via write, verify the
      # callback sees the binding. Exercises `addReader2`'s `userCallback`
      # wiring end-to-end.
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
    # docs §Test plan: combinators propagate context to their
    # continuations. `race(fa, fb)` installs callbacks on each future;
    # the resolver fires when the first completes, then the awaiter
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
    # docs §Test plan: `allFutures(fa, fb)` waits for both; the awaiter's
    # binding must be visible after the combinator resolves, not one
    # of the child task's bindings.
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
    # docs §Test plan. On Linux, `closeHandle` forwards to
    # `closeSocket`; on Windows it has its own IOCP path. Pinned
    # separately from `closeSocket` so a future divergence between
    # the two doesn't silently lose context propagation on either.
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
    # Per docs §Capture discipline, the scheduling site uses `userCallback`
    # so the callback fires under the context bound at close-call time.
    # Regression guard against drift to `internalCallback` (which would
    # drop the caller's context).
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
    # docs §Bridging independent callbacks: an enter hook and a
    # separately-fired exit hook (no await or shared call stack between
    # them) are not a single logical task, so no binder can span them -
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
    # context-blind internal trampoline (`internalCallback`, no
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

suite "contextvars: RFC0001 D0/D1 fast-path pins":
  # These tests pin the observable contract `withRestoredContext`/
  # `fireWithContext` must hold across both the identity fast arm (no
  # writes to `currentAsyncContext`) and the slow arm (write + restore).
  # They are regression guards, not drivers of a behavior change - the
  # dispatcher already restored context correctly before D0/D1 (via the
  # unconditional save/restore `fireWithContext` used to perform
  # directly); D0/D1 only add the identity short-circuit. All three are
  # expected green against the dispatcher both before and after the D0/D1
  # refactor. See RFC 0001 §3 D0/D1, §6 S3.

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
    # Fast-arm coverage for exit class 2 (raise), RFC 0001 §3 D1. The
    # callback below is scheduled with no ambient binder, so its
    # captured (nil) context equals the ambient (nil) context at fire
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
        doAssert false, "contextvars S3(b): intentional Defect to " &
                         "exercise the fast-arm raise path"

    callSoon(raiser, nil)
    var caught = false
    try:
      poll()
    except Defect:
      caught = true
    check caught
    check asyncInt() == 0

  test "nil-captured resume through a suspended binder leaves the ambient context clean for a later same-batch callback (D1 x D3 leak-repro pin)":
    # RFC 0001 D3: `internalContinue`'s resume must restore
    # `currentAsyncContext` even when the resumed slice suspends AGAIN
    # inside a binder before returning control to the dispatcher (an
    # iterator `yield` inside a `withName` block is a plain return -
    # `contextBindSlot`'s `finally` does not run for it). Without that
    # restore, D1's fast arm at the OUTER fire (identity nil == nil)
    # would leave the threadvar pointing at the binder's node for every
    # callback still queued behind it in the same batch.
    # `futureContinue`'s own unconditional save/restore is the
    # load-bearing net (present independently of D0/D1); this test pins
    # the observable end-to-end behavior rather than the mechanism, so
    # it stays valid across the S5 refactor onto `pinContext`.
    let outerWaiter = newFuture[void]("s3.leak-repro.outer")
    let innerWaiter = newFuture[void]("s3.leak-repro.inner")
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

