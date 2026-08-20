#                  Tonalli Test Suite
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## RFC 0012 stage 6: the shared registry of replayable simulation
## fixture bodies. Every entry here is a `sweepSeeds`/`sweepSeedsWith`
## body extracted verbatim out of a sim test suite, as a named template,
## so `tests/simreplay.nim` can drive it from a downloaded failing-seed
## trace (`simulateReplay`/`simulateReplayWith`) without hand-copying
## the body out of the test file. The owning suite still sweeps its
## fixture through the template below - same body, same seeds, same
## opts - so this module changes where the code lives, not what it
## does. `fixtureNames` enumerates every registered name; a fixture that
## was swept with `sweepSeedsWith` also exports its own `SimRunOptions`
## proc (e.g. `simulationLedgerFixtureOpts`) so it replays with
## `simulateReplayWith` instead of plain `simulateReplay`.

import std/strutils
import ../tonalli
import ../tonalli/simulation
import ../tonalli/contextvars
import ../tonalli/streams/asyncstream

when defined(chronosSimulation):
  const
    fixtureNames* = [
      "callbackqueue-callsoon-fifo-order",
      "callbackqueue-idler-fires-on-empty-batch",
      "contextvars-binding-survives-sequential-awaits",
      "contextvars-concurrent-tasks-stay-isolated",
      "contextvars-child-inherits-no-leak-back",
      "contextvars-exception-across-await-reverts-binding",
      "contextvars-cancelled-error-via-timer-reverts-binding",
      "simnet-pipelined-echo-under-partial-completions",
      "simulation-sweep-runs-every-seed-empty-body",
      "simulation-sweep-with-ledger-classifies-violating-seed",
    ]
      ## `tests/testsimulation.nim:761`'s `sweepSeedsWith` call is
      ## excluded on purpose: it tests that an explicit `opts.oracle`
      ## is *refused*, a negative-path assertion on the harness itself
      ## rather than a fixture over application code, so there is
      ## nothing meaningful to replay.

  # tests/testcallbackqueue.nim -------------------------------------

  template callbackqueueCallSoonFifoOrderFixture*(): untyped =
    var order: seq[int]
    for i in 0 ..< 16:
      callSoon(proc(arg: pointer) {.gcsafe, raises: [].} =
        order.add(cast[int](arg)), cast[pointer](i))
    # `poll()` cannot be called directly from async code (illegal
    # `NestedPoll` effect); yielding once drains the already-queued
    # callbacks, since `processCallbacks` always runs to completion
    # each poll iteration regardless of the timer that wakes it.
    await sleepAsync(0.milliseconds)
    var expected: seq[int]
    for i in 0 ..< 16: expected.add i
    if order != expected:
      raise newException(ValueError, "FIFO order violated: " & $order)

  template callbackqueueIdlerFiresOnEmptyBatchFixture*(): untyped =
    var idlerFired = false
    callIdle(proc(arg: pointer) {.gcsafe, raises: [].} = idlerFired = true)
    await sleepAsync(0.milliseconds)
    if not idlerFired:
      raise newException(ValueError, "idler did not fire on an empty batch")

  # tests/testcontextvarsasync.nim -----------------------------------

  let contextvarsFixtureInt* = newContextVar("simFixtureAsyncInt", 0)
    ## A fixture-local twin of `testcontextvarsasync.nim`'s `asyncInt`:
    ## that context var stays put (the file's non-sim tests still bind
    ## it directly), so the sim-legal fixtures below get their own
    ## instance rather than reaching across module boundaries for it.

  template contextvarsBindingSurvivesSequentialAwaitsFixture*(): untyped =
    contextvarsFixtureInt.withValue(11):
      if contextvarsFixtureInt.value != 11:
        raise newException(ValueError,
          "wrong binding before first await: " & $contextvarsFixtureInt.value)
      await sleepAsync(1.milliseconds)
      if contextvarsFixtureInt.value != 11:
        raise newException(ValueError,
          "wrong binding after first await: " & $contextvarsFixtureInt.value)
      await sleepAsync(1.milliseconds)
      if contextvarsFixtureInt.value != 11:
        raise newException(ValueError,
          "wrong binding after second await: " & $contextvarsFixtureInt.value)

  template contextvarsConcurrentTasksStayIsolatedFixture*(): untyped =
    var tickA = newFuture[void]("tickA")
    var tickB = newFuture[void]("tickB")

    proc taskA(): Future[int] {.async: (raises: [CatchableError]).} =
      contextvarsFixtureInt.withValue(100):
        await tickA
        if contextvarsFixtureInt.value != 100:
          raise newException(ValueError,
            "task A saw " & $contextvarsFixtureInt.value & " instead of 100")
        return contextvarsFixtureInt.value

    proc taskB(): Future[int] {.async: (raises: [CatchableError]).} =
      contextvarsFixtureInt.withValue(200):
        await tickB
        if contextvarsFixtureInt.value != 200:
          raise newException(ValueError,
            "task B saw " & $contextvarsFixtureInt.value & " instead of 200")
        return contextvarsFixtureInt.value

    let fa = taskA()
    let fb = taskB()
    tickA.complete()
    tickB.complete()
    let a = await fa
    let b = await fb
    if a != 100 or b != 200:
      raise newException(ValueError, "wrong results: a=" & $a & " b=" & $b)

  template contextvarsChildInheritsNoLeakBackFixture*(): untyped =
    proc child(): Future[void] {.async: (raises: [CancelledError, ValueError]).} =
      if contextvarsFixtureInt.value != 42:
        raise newException(ValueError,
          "child did not inherit parent's binding: saw " & $contextvarsFixtureInt.value)
      contextvarsFixtureInt.withValue(999):
        await sleepAsync(1.milliseconds)
        if contextvarsFixtureInt.value != 999:
          raise newException(ValueError,
            "child's own binding lost across await: saw " & $contextvarsFixtureInt.value)
      if contextvarsFixtureInt.value != 42:
        raise newException(ValueError,
          "child did not revert to parent's binding: saw " & $contextvarsFixtureInt.value)

    contextvarsFixtureInt.withValue(42):
      await child()
      if contextvarsFixtureInt.value != 42:
        raise newException(ValueError,
          "child's binding leaked back into parent: saw " & $contextvarsFixtureInt.value)

  template contextvarsExceptionAcrossAwaitRevertsBindingFixture*(): untyped =
    proc work(): Future[void] {.async: (raises: [CancelledError, ValueError]).} =
      await sleepAsync(1.milliseconds)
      raise newException(ValueError, "boom across await")

    var reachedUnreachable = false
    try:
      contextvarsFixtureInt.withValue(77):
        await work()
        reachedUnreachable = true
    except ValueError as exc:
      if not strutils.contains(exc.msg, "boom across await"):
        raise newException(ValueError, "wrong exception propagated: " & exc.msg)
    if reachedUnreachable:
      raise newException(ValueError, "expected exception did not propagate")
    if contextvarsFixtureInt.value != 0:
      raise newException(ValueError,
        "binding not reverted after exception: saw " & $contextvarsFixtureInt.value)

  template contextvarsCancelledErrorViaTimerRevertsBindingFixture*(): untyped =
    proc longSleep(): Future[void] {.async: (raises: [CancelledError]).} =
      await sleepAsync(1.seconds)

    let f = longSleep()
    var reachedUnreachable = false
    var observed = -1
    try:
      contextvarsFixtureInt.withValue(55):
        discard setTimer(Moment.now() + 1.milliseconds,
          proc(_: pointer) {.gcsafe, raises: [].} = f.cancelSoon())
        await f
        reachedUnreachable = true
    except CancelledError:
      observed = contextvarsFixtureInt.value
    if reachedUnreachable:
      raise newException(ValueError, "cancellation did not propagate")
    if observed != 0:
      raise newException(ValueError,
        "binding not reverted after cancellation: saw " & $observed)

  # tests/testsimnet.nim ----------------------------------------------

  const
    simnetFixtureChunkSize* = 8
    simnetFixtureMessages* = ["message1", "message2", "message3"]

  proc simnetFixtureToStr*(b: seq[byte]): string =
    result = newString(b.len)
    if b.len > 0:
      copyMem(addr result[0], unsafeAddr b[0], b.len)

  proc simnetFixtureRunPipelinedEcho*(client, server: StreamTransport):
      Future[seq[string]] {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
    ## The parametrized echo body `tests/testsimnet.nim` sweeps (RFC
    ## 0003 6, S11a/S11b): the client pipelines every write before
    ## awaiting any of them, the server echoes each fixed-size chunk
    ## back in arrival order, and the client reads every echo.
    proc serverLoop() {.async: (raises: [TransportError, CancelledError, SimBarrierError, SimEngineError]).} =
      for _ in simnetFixtureMessages:
        var buf = newSeq[byte](simnetFixtureChunkSize)
        await server.readExactly(addr buf[0], simnetFixtureChunkSize)
        discard await server.write(buf)
    let serverFut = serverLoop()

    var writeFuts: seq[Future[int].Raising([TransportError, CancelledError])]
    for m in simnetFixtureMessages:
      writeFuts.add client.write(m)
    for f in writeFuts:
      discard await f

    result = @[]
    for _ in simnetFixtureMessages:
      var buf = newSeq[byte](simnetFixtureChunkSize)
      await client.readExactly(addr buf[0], simnetFixtureChunkSize)
      result.add simnetFixtureToStr(buf)
    await serverFut

  template simnetPipelinedEchoUnderPartialCompletionsFixture*(): untyped =
    let net = simNet()
    let address = initTAddress("127.0.0.1:0")
    let server = net.listenStream(address)
    let acceptFut = server.accept()
    let client = await net.connectStream(address)
    let serverTransp = await acceptFut
    let echoes = await simnetFixtureRunPipelinedEcho(client, serverTransp)
    if echoes != @simnetFixtureMessages:
      raise newException(ValueError,
        "sweep echo mismatch: got " & $echoes & ", expected " &
          $(@simnetFixtureMessages))
    await client.closeWait()
    await serverTransp.closeWait()

  # tests/testsimulation.nim ------------------------------------------

  template simulationSweepRunsEverySeedEmptyBodyFixture*(): untyped =
    discard

  var simulationLedgerFixtureRunIndex* = 0
    ## The planted violation fires only on the sweep's second seed
    ## (`== 2`), the same shape `tests/testsimulation.nim`'s original
    ## body used - a property of that seed's *position in the swept
    ## range*, not of anything the trace itself records. The caller
    ## resets this to 0 before sweeping (`tests/testsimulation.nim`) or
    ## to 1 before replaying the one seed that violated
    ## (`resetSimulationLedgerFixtureForReplay` below) - a standalone
    ## replay has no sibling seeds ahead of it to advance the counter
    ## the way the sweep did.

  template simulationSweepWithLedgerClassifiesViolatingSeedFixture*(): untyped =
    await sleepAsync(0.milliseconds)
    inc simulationLedgerFixtureRunIndex
    if simulationLedgerFixtureRunIndex == 2:
      simLedgerDebugPlantDroppedEnqueue(SimLedgerQueueKind.Callbacks)
    await sleepAsync(0.milliseconds)

  proc simulationLedgerFixtureOpts*(): SimRunOptions =
    simOptions(ledger = true)

  proc resetSimulationLedgerFixtureForReplay*() =
    ## `tests/simreplay.nim` calls this before replaying
    ## `simulation-sweep-with-ledger-classifies-violating-seed`: the
    ## trace being replayed is always the seed that violated (nobody
    ## downloads a passing seed's trace), so this puts the counter
    ## where it stood the moment that seed's own run started in the
    ## original sweep, one below the trigger.
    simulationLedgerFixtureRunIndex = 1
