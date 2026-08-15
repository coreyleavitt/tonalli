#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## The deterministic simulation substrate's public surface (RFC 0003
## 3.10): `simulate`, the single-run harness primitive that runs an
## async body on a fresh hermetic sim dispatcher and restores the
## thread's real dispatcher afterward, whatever the body's outcome.
##
## Re-exports `chronos/internal/simengine` (which itself re-exports
## `chronos/internal/simtrace` and `chronos/internal/simledger`), so
## this is the one import a sim test needs beyond `chronos` itself:
## `SimOracle` and its choice-point/decision types, `newSimOracle`,
## `RandomOracle`, `ReplayOracle`, `SimBarrierError`, `SimEngineError`,
## `SimFailureKind`, `SimLedgerError`, and the trace schema.

import std/[deques, os, strutils, tables]
import unittest2
import ../chronos
import ./internal/simengine
import ./internal/simclock

export simengine

type
  SimulationError* = object of CatchableError
    ## Raised by `simulate()` for any run failure, seed- and trace-
    ## attributed so a failing seed is a complete bug report (RFC 0003
    ## 3.8). `parent` (inherited from `Exception`) holds the original
    ## exception: the body's own error, or the internal `SimEngineError`
    ## `runSimulation` caught and converted. `kind` (`SimFailureKind`,
    ## `chronos/internal/simengine.nim`) classifies which by a type-safe
    ## field on that internal exception - never by parsing `msg` - with
    ## one exception of its own: `BodyError` is set here, not carried on
    ## any raised exception, since it names "the failure was not one of
    ## the engine's own" rather than a specific engine-detected kind.
    kind*: SimFailureKind
    seed*: uint64
    tracePath*: string

const
  simulateDefaultDecisionBudget* = 10_000
    ## Generous default (RFC 0003 3.8): every oracle `decide*` call
    ## counts against it, so ordinary tests never come close.
  simulateDefaultTimeBudget* = seconds(3_600)
    ## Generous default: an hour of virtual time.

type
  SimStreamServer* = ref object
    ## A `listenStream` binding (RFC 0003 3.2/3.8, S11a): connection
    ## establishment is sim-native, not seamed, so this is plain
    ## chronos Future coordination, not an oracle choice point -
    ## `connectStream` mints an already-connected pair and hands the
    ## server side either to a waiting `accept()` or to `pending` for
    ## a later one.
    pending: Deque[StreamTransport]
    waiters: Deque[Future[StreamTransport]]

  SimNet* = object
    ## Attaches to the current run's sim network (RFC 0003 3.8): one
    ## per sim dispatcher - every `simNet()` call against the same
    ## dispatcher sees the same listener bindings.
    disp: PDispatcher

var simNetListeners {.threadvar.}: Table[TransportAddress, SimStreamServer]
  ## Per-run listener bindings (RFC 0003 3.8's "one sim network per
  ## sim dispatcher"), reset at the start of every `runSimulation` call
  ## so a fresh run never sees a previous run's `listenStream`
  ## bindings. Keyed by address rather than carried on `SimEngineState`
  ## (chronos/internal/simengine.nim): a `StreamTransport`-typed
  ## listener table belongs above the leaf/private engine layer, which
  ## stays transport-agnostic (RFC 0003 3.10's module layout).

proc resetSimNet() =
  simNetListeners = initTable[TransportAddress, SimStreamServer]()

proc simNet*(): SimNet =
  ## Attaches to the current run's sim network (RFC 0003 3.8):
  ## `listenStream`/`connectStream` mint already-connected endpoint
  ## pairs sim-natively (RFC 0003 3.2) - the real accept/connect/
  ## shutdown state machines are not exercised under simulation, a
  ## recorded coverage concession. `SimNet`'s type and this accessor
  ## compile and type-check on every platform; `listenStream`/
  ## `connectStream` are POSIX-only in this slice below, matching the
  ## stream I/O seam they build on (RFC section 4's Windows IOCP-
  ## emulation non-goal, already accepted at S10).
  let disp = getThreadDispatcher()
  doAssert disp.isSimDispatcher(), "simNet() requires a simulated dispatcher"
  SimNet(disp: disp)

type
  SimProducer* = object
    ## An arrival actor bound to the current run's sim dispatcher (RFC
    ## 0003 3.6, S13): the sim-legal replacement for spawning a real OS
    ## thread and minting a `DispatcherHandle` to call `callSoon`
    ## cross-thread - both `handle()` and `wake()` barrier under
    ## simulation and their docstrings point here instead. Platform-
    ## neutral: the machinery behind `post()` is dispatcher-level
    ## (the real MPSC `threadCallbacks` queue and `waking` flag), not
    ## seamed I/O, so it needs no POSIX/Windows split.
    disp: PDispatcher

proc simProducer*(): SimProducer =
  ## Attaches to the current run's sim dispatcher (RFC 0003 3.6).
  let disp = getThreadDispatcher()
  doAssert disp.isSimDispatcher(), "simProducer() requires a simulated dispatcher"
  SimProducer(disp: disp)

proc post*(producer: SimProducer, cbproc: ThreadCallbackFunc,
           udata: pointer = nil) =
  ## Schedules `cbproc` for cross-thread-style delivery (RFC 0003 3.6):
  ## fires with `bareCallback` semantics, no captured context, the same
  ## as a genuine cross-thread `callSoon` - the modeled producer is a
  ## different (simulated) thread. Delivered as an `Arrival` SimEvent
  ## through `decideBatch`, subject to the coalescing constraint: a
  ## post landing before a still-pending arrival's delivery joins it
  ## rather than minting a second one.
  simProducerPost(producer.disp, cbproc, udata)

when not defined(windows):
  proc listenStream*(net: SimNet, address: TransportAddress): SimStreamServer =
    ## Binds a sim listener at `address` (RFC 0003 3.8). Idempotent
    ## re-binding is not modeled: a second `listenStream` at the same
    ## address is a test-authoring bug in this harness, not a runtime
    ## condition a real caller must handle, so it asserts rather than
    ## returning a catchable error.
    doAssert address notin simNetListeners,
      "listenStream(): " & $address & " already has a listener"
    result = SimStreamServer()
    simNetListeners[address] = result

  proc accept*(server: SimStreamServer):
      Future[StreamTransport] {.async: (raises: [CancelledError]).} =
    ## Returns the next connection `connectStream` mints against this
    ## listener - already available in `pending`, or awaited via a
    ## waiter `connectStream` completes directly (RFC 0003 3.8's
    ## sketch: the `accept()`-style shape `stream.nim`'s own explicit
    ## `StreamServer.accept()` uses, so a parametrized test body can
    ## treat a sim and a real server identically).
    if server.pending.len > 0:
      return server.pending.popFirst()
    let fut = Future[StreamTransport].Raising([CancelledError]).init(
      "simnet.accept")
    server.waiters.addLast(fut)
    await fut

  proc connectStream*(net: SimNet, address: TransportAddress):
      Future[StreamTransport] {.async: (raises: [
        TransportError, CancelledError, SimBarrierError]).} =
    ## Mints an already-connected pair (RFC 0003 3.2's sim-native
    ## connection setup) and returns the client side, handing the
    ## server side to `address`'s listener - directly to a waiting
    ## `accept()` if one is already parked, `pending` otherwise.
    ## Widened for `SimBarrierError`: this always runs under
    ## `-d:chronosSimulation` (fork issue #19's typed sim error channel;
    ## `simStreamPair`, `chronos/transports/stream.nim`, raises it
    ## directly, though this slice proves it unreachable here - the
    ## dispatcher is already proven simulated by `simNet()`'s own
    ## `doAssert`, and this module mints no real fd for it to barrier
    ## against).
    let server = simNetListeners.getOrDefault(address)
    doAssert not server.isNil,
      "connectStream(): no listener at " & $address
    let (clientTransp, serverTransp) = simStreamPair()
    if server.waiters.len > 0:
      let waiter = server.waiters.popFirst()
      waiter.complete(serverTransp)
    else:
      server.pending.addLast(serverTransp)
    clientTransp

  proc datagramPair*(net: SimNet, addrA, addrB: TransportAddress,
                      cbprocA, cbprocB: DatagramCallback,
                      udataA: pointer = nil, udataB: pointer = nil
                     ): tuple[a, b: DatagramTransport] {.
      raises: [TransportOsError, SimBarrierError].} =
    ## Mints a connected pair of sim datagram endpoints (RFC 0003 6,
    ## S12b) - the datagram-flavored analogue of `listenStream`/
    ## `connectStream`'s stream pairing above, minus the listen/accept
    ## ceremony: UDP has no connection handshake to mint sim-natively,
    ## so both sides are wired atomically in one call rather than a
    ## listener/dialer pair. Widened for `SimBarrierError`, the same
    ## always-sim-only reasoning `connectStream` documents:
    ## `simDatagramPair` (`chronos/transports/datagram.nim`) raises it
    ## directly, though this slice proves it unreachable here too.
    simDatagramPair(addrA, addrB, cbprocA, cbprocB, udataA, udataB)
else:
  proc listenStream*(net: SimNet, address: TransportAddress): SimStreamServer =
    ## `SimNet` stream transports are POSIX-only in this slice: the
    ## S10 read/write seam `simStreamPair` builds on exists only in
    ## `stream.nim`'s POSIX branch (RFC section 4's Windows IOCP-
    ## emulation non-goal). This compiles and type-checks on Windows -
    ## satisfying `nimble check_windows` - and fails loudly rather than
    ## silently doing nothing if ever reached there.
    raiseAssert "SimNet stream transports are not implemented on " &
      "Windows (RFC 0003 section 4's Windows IOCP-emulation non-goal)"

  proc accept*(server: SimStreamServer):
      Future[StreamTransport] {.async: (raises: [CancelledError]).} =
    raiseAssert "SimNet stream transports are not implemented on " &
      "Windows (RFC 0003 section 4's Windows IOCP-emulation non-goal)"

  proc connectStream*(net: SimNet, address: TransportAddress):
      Future[StreamTransport] {.async: (raises: [TransportError, CancelledError]).} =
    raiseAssert "SimNet stream transports are not implemented on " &
      "Windows (RFC 0003 section 4's Windows IOCP-emulation non-goal)"

  proc datagramPair*(net: SimNet, addrA, addrB: TransportAddress,
                      cbprocA, cbprocB: DatagramCallback,
                      udataA: pointer = nil, udataB: pointer = nil
                     ): tuple[a, b: DatagramTransport] {.
      raises: [TransportOsError].} =
    ## `SimNet` datagram transports are POSIX-only in this slice, the
    ## same non-goal `listenStream`/`connectStream` above already
    ## document: the datagram I/O seam this builds on (S12a) is POSIX-
    ## only. Compiles and type-checks on Windows - satisfying `nimble
    ## check_windows` - and fails loudly rather than silently doing
    ## nothing if ever reached there.
    raiseAssert "SimNet datagram transports are not implemented on " &
      "Windows (RFC 0003 section 4's Windows IOCP-emulation non-goal)"

proc newSimulationError(kind: SimFailureKind, seed: uint64, tracePath, msg: string,
                         parent: ref Exception): ref SimulationError =
  result = newException(SimulationError,
    "simulation failed (seed=0x" & toLowerAscii(toHex(seed)) & "): " & msg)
  result.kind = kind
  result.seed = seed
  result.tracePath = tracePath
  result.parent = parent

proc simTracePath(seed: uint64): string =
  getTempDir() / "chronos-sim" / ("seed-" & $seed & ".ndjson")

proc runSimulation(seed: uint64, decisionBudget: int, timeBudget: Duration,
                    enableLedger: bool,
                    body: proc(): Future[void] {.gcsafe.}) =
  ## The harness core behind the `simulate` template (RFC 0003 3.8):
  ## saves the thread's current dispatcher without side effects,
  ## installs a fresh hermetic sim dispatcher seeded with `RandomOracle
  ## (seed)` and the given budgets, prints and flushes the seed banner,
  ## runs `body` to completion, and restores the saved dispatcher
  ## through the force path - unconditionally, whether `body` completed,
  ## the body raised, or the sim loop itself failed - so the original
  ## failure always survives and the calling thread's real dispatcher
  ## is always left intact. `enableLedger` turns on the D8 ghost-ledger
  ## laws (RFC 0003 3.9, slice S14); see `simulateWithLedger`.
  let savedDisp = getThreadDispatcherOrNil()
  let tracePath = simTracePath(seed)
  createDir(tracePath.parentDir)
  var writer = openSimTraceWriter(tracePath, seed = seed)
  let timeBudgetCutoffNanoseconds =
    simClockAnchorNanoseconds + timeBudget.nanoseconds
  let disp = newSimDispatcher(oracle = RandomOracle(seed),
    decisionBudget = decisionBudget, seed = seed, hasTimeBudget = true,
    timeBudgetCutoffNanoseconds = timeBudgetCutoffNanoseconds,
    enableLedger = enableLedger)
  disp.simAttachTraceWriter(addr writer)

  stdout.writeLine("[chronos-sim] seed=" & $seed & " trace=" & tracePath)
  stdout.flushFile()

  # Force path both ways (not only on restore, below): under the
  # default non-strict-reentrancy mode, any constructed-or-polled
  # dispatcher permanently carries the sentinel callback, so
  # `savedDisp.callbacks.len` is 1, never 0.
  forceSetThreadDispatcher(disp)
  activateSimClock()
  resetSimNet()

  var failure: ref SimulationError = nil
  var ledgerFailure: ref SimLedgerError = nil
  try:
    waitFor body()
    if enableLedger:
      # Only on a clean body completion (RFC 0003 3.9's teardown check
      # "so nothing escapes between the last fire and exit" - a body
      # that already raised has a failure of its own to report, and it
      # takes priority over a secondary reconciliation issue, the same
      # priority `Restore is exception-safe` (3.8) already gives the
      # original failure over a masking restore-time assert).
      simLedgerTeardownCheck(disp)
  except SimLedgerError as exc:
    exc.seed = seed
    ledgerFailure = exc
  except SimEngineError as exc:
    failure = newSimulationError(exc.kind, seed, tracePath, exc.msg, exc)
  except CatchableError as exc:
    # Every other failure, including `SimBarrierError` (raised directly
    # by a provenance-guarded touch site the body reached, `object of
    # CatchableError`, deliberately not a subtype of `AsyncError` - see
    # its own docstring): from `runSimulation`'s perspective this is
    # indistinguishable from any other exception the body's own code
    # raised, which is exactly right - `BodyError` names "not one of
    # the engine's own typed failures", not "the body's logic is at
    # fault".
    failure = newSimulationError(SimFailureKind.BodyError, seed, tracePath,
                                  exc.msg, exc)
  except Defect as exc:
    # A handful of touch sites cross a `raises: []`-typed boundary no
    # per-build pragma can widen - a `CallbackFunc` (the transport
    # seam's I/O-callback `simRawIo` wrap and its `register2`/
    # `addReader2`/etc. teardown calls, `chronos/transports/
    # stream.nim`'s `simBoundaryGuard`/`safeRegister2`-family helpers
    # and `chronos/transports/datagram.nim`'s equivalents) or
    # `finish()`'s unbounded reach (`chronos/internal/asyncfutures.nim`'s
    # `simLedgerNoteFutureFinish`) - documented at each site. Each
    # catches its own typed `SimBarrierError`/`SimEngineError`/
    # `SimLedgerError` locally and re-raises it wrapped in a `Defect`
    # (`raiseAsDefect`, exempt from the raises effect system - the same
    # mechanism `raiseOsDefect` already uses to cross an unwidenable
    # boundary for an unrecoverable real-mode condition) instead of
    # letting it propagate normally. Recovered here, by type
    # (`exc.parent of ...`), never by parsing `exc.msg` - the one
    # narrow, type-checked exception to this retirement round's "no
    # Defect trampoline" aim, forced by those boundaries' reach rather
    # than chosen for convenience. Any other `Defect` (a genuine
    # unrecoverable condition, e.g. `raiseOsDefect`) is not this
    # round's concern and re-raises unchanged.
    if not exc.parent.isNil and exc.parent of SimLedgerError:
      let ledgerExc = (ref SimLedgerError)(exc.parent)
      ledgerExc.seed = seed
      ledgerFailure = ledgerExc
    elif not exc.parent.isNil and exc.parent of SimEngineError:
      let engineExc = (ref SimEngineError)(exc.parent)
      failure = newSimulationError(engineExc.kind, seed, tracePath,
                                    engineExc.msg, engineExc)
    elif not exc.parent.isNil and exc.parent of SimBarrierError:
      # As the direct-propagation `SimBarrierError` case above
      # (`except CatchableError`): indistinguishable from the body's
      # own failure.
      failure = newSimulationError(SimFailureKind.BodyError, seed,
                                    tracePath, exc.parent.msg, exc.parent)
    else:
      raise exc
  finally:
    deactivateSimClock()
    disp.simAttachTraceWriter(nil)
    forceSetThreadDispatcher(savedDisp)
    writer.close()

  if ledgerFailure != nil:
    raise ledgerFailure
  if failure != nil:
    raise failure

template simulate*(seed: uint64, body: untyped): untyped =
  ## Runs `body` (async code) to completion on a fresh, hermetic
  ## simulated dispatcher driven by `RandomOracle(seed)`, then restores
  ## the calling thread's real dispatcher - even if `body` raises or
  ## the simulation itself fails. A run that exceeds the default
  ## decision/time budget (RFC 0003 3.8), deadlocks, or hits an oracle/
  ## protocol violation raises `SimulationError`, and so does a raising
  ## `body` (unwrapped as `.parent`). See `simulateWithBudget` to
  ## override the budgets, and `simulateWithLedger` to additionally
  ## check RFC 0003 3.9's ghost-ledger conservation laws.
  runSimulation(seed, simulateDefaultDecisionBudget, simulateDefaultTimeBudget,
    enableLedger = false,
    proc() {.async, gcsafe.} =
      body)

template simulateWithLedger*(seed: uint64, body: untyped): untyped =
  ## As `simulate`, additionally checking RFC 0003 3.9's ghost-ledger
  ## conservation laws (callback conservation, future lifecycle) at
  ## every step boundary and at teardown - slice S14. A violation
  ## raises `SimLedgerError`, distinct by type from `SimulationError`
  ## (3.9: "a test distinguishes a ledger violation from a barrier hit
  ## or oracle failure by type, never by string-matching the message").
  ## A separate entry point rather than a flag on `simulate`: every
  ## pre-S14 caller of `simulate`/`sweepSeeds` is unaffected, since
  ## ledger checking depends on producer coverage this slice does not
  ## claim to be exhaustive over (see `tests/testsimledger.nim`'s
  ## module docstring for the scoping judgment call).
  runSimulation(seed, simulateDefaultDecisionBudget, simulateDefaultTimeBudget,
    enableLedger = true,
    proc() {.async, gcsafe.} =
      body)

template simulateWithBudget*(seed: uint64, decisionBudget: int,
                              timeBudget: Duration, body: untyped): untyped =
  ## As `simulate`, with `decisionBudget`/`timeBudget` overriding the
  ## defaults - the bounds a livelock trips at (RFC 0003 3.8). A
  ## separate template rather than an overload of `simulate`: with both
  ## sharing a name, resolving a call to either miscompiles `await` in
  ## `body` (reproduced standalone against the Nim 2.2.10 toolchain;
  ## not specific to this module).
  runSimulation(seed, decisionBudget, timeBudget, enableLedger = false,
    proc() {.async, gcsafe.} =
      body)

proc simLedgerDebugPlantDroppedEnqueue*(kind: SimLedgerQueueKind) =
  ## TEST-ONLY escape hatch (RFC 0003 slice S14's RED phase): records
  ## an `enqueue` the ledger will never observe a matching `fired`/
  ## `nilPop`/still-queued for, planting the callback-conservation
  ## law's "dropped callback" violation - the #703 bug class (a queued
  ## callback surviving the frame that owns its captured state)
  ## caught structurally, without needing an actual crash to
  ## reproduce it. Requires a currently-running `simulateWithLedger`
  ## body; not part of the stable API.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugPlantDroppedEnqueue() requires simulateWithLedger()"
  ledger.noteEnqueue(kind)

proc simLedgerDebugCurrentStep*(): int =
  ## TEST-ONLY (RFC 0003 slice S14): the ledger's current step index -
  ## `tests/testsimledger.nim` uses this to pin that a synchronous
  ## cancellation cascade does not advance it (3.9: cascades account to
  ## the enclosing step). Requires a currently-running
  ## `simulateWithLedger` body; not part of the stable API.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugCurrentStep() requires simulateWithLedger()"
  ledger.currentStep()

proc simLedgerDebugNilPopCount*(kind: SimLedgerQueueKind): uint64 =
  ## TEST-ONLY (RFC 0003 slice S14): see `simLedgerDebugCurrentStep`.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugNilPopCount() requires simulateWithLedger()"
  ledger.nilPopCount(kind)

proc simLedgerDebugPlantContextImbalance*() =
  ## TEST-ONLY escape hatch (RFC 0003 slice S15's RED phase), the
  ## contextvar-conservation analogue of
  ## `simLedgerDebugPlantDroppedEnqueue`: records a `captured` the
  ## ledger will never observe a matching `restored`/still-resident for,
  ## planting the "capture and restore balance across every scheduling
  ## point" law's violation without needing a genuine capture/restore
  ## bug to reproduce it. Requires a currently-running
  ## `simulateWithLedger` body; not part of the stable API.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugPlantContextImbalance() requires simulateWithLedger()"
  ledger.noteContextCaptured()

proc simLedgerDebugPlantTimerImbalance*() =
  ## TEST-ONLY escape hatch (RFC 0003 slice S15's RED phase), the timer-
  ## accounting analogue of `simLedgerDebugPlantDroppedEnqueue`: records
  ## an `armed` the ledger will never observe a matching `fired`/
  ## `cancelled`/still-pending for. Requires a currently-running
  ## `simulateWithLedger` body; not part of the stable API.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugPlantTimerImbalance() requires simulateWithLedger()"
  ledger.noteTimerArmed()

proc simLedgerRegisterWaiter*(desc: string,
    countProc: proc(): int {.gcsafe, raises: [].}) =
  ## Opts one asyncsync primitive into RFC 0003 3.9's waiter-
  ## conservation law (the 2026-08-15 amendment, slice S15): `desc`
  ## names it in a violation, `countProc` is typically the primitive's
  ## own `waitersCount`/`gettersCount`/`puttersCount` accessor. The
  ## generic, low-level entry point behind the typed
  ## `simLedgerTrackWaiters` overloads below - use those directly
  ## unless tracking a primitive they don't cover. Requires a currently-
  ## running `simulateWithLedger` body.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerRegisterWaiter() requires simulateWithLedger()"
  ledger.registerWaiterPrimitive(desc, countProc)

proc simLedgerTrackWaiters*(lock: AsyncLock) =
  ## Opts `lock` into waiter conservation (RFC 0003 3.9's 2026-08-15
  ## amendment). Call once per instance, after construction, from
  ## inside a `simulateWithLedger` body.
  simLedgerRegisterWaiter("AsyncLock.waiters",
    proc(): int {.gcsafe, raises: [].} = lock.waitersCount())

proc simLedgerTrackWaiters*(event: AsyncEvent) =
  ## As `simLedgerTrackWaiters(AsyncLock)`, for `AsyncEvent`.
  simLedgerRegisterWaiter("AsyncEvent.waiters",
    proc(): int {.gcsafe, raises: [].} = event.waitersCount())

proc simLedgerTrackWaiters*[T](aq: AsyncQueue[T]) =
  ## As `simLedgerTrackWaiters(AsyncLock)`, for `AsyncQueue` - tracks
  ## `getters` and `putters` as two separately-named waiter lists, per
  ## RFC 0003 3.9's "per waiter list" phrasing.
  simLedgerRegisterWaiter("AsyncQueue.getters",
    proc(): int {.gcsafe, raises: [].} = aq.gettersCount())
  simLedgerRegisterWaiter("AsyncQueue.putters",
    proc(): int {.gcsafe, raises: [].} = aq.puttersCount())

proc simLedgerTrackWaiters*[T](ab: AsyncEventQueue[T]) =
  ## As `simLedgerTrackWaiters(AsyncLock)`, for `AsyncEventQueue` - the
  ## 2026-08-15 amendment's addition beyond
  ## `feat/asyncsync-waiters-introspection`'s original four primitives;
  ## `ab.waitersCount()` is this slice's own accessor (`asyncsync.nim`),
  ## added in the same uniform style.
  simLedgerRegisterWaiter("AsyncEventQueue.readers",
    proc(): int {.gcsafe, raises: [].} = ab.waitersCount())

proc simLedgerTrackWaiters*(s: AsyncSemaphore) =
  ## As `simLedgerTrackWaiters(AsyncLock)`, for `AsyncSemaphore`.
  simLedgerRegisterWaiter("AsyncSemaphore.waiters",
    proc(): int {.gcsafe, raises: [].} = s.waitersCount())

type
  SimSeedOutcome* = object
    ## One seed's verdict from `sweepSeeds`/`collectSweepSeeds` (RFC 0003
    ## 3.8): every seed in the swept range gets exactly one of these, in
    ## seed order, whether it passed or failed - the sweep never stops
    ## at the first failure, so a multi-seed bug never hides its
    ## siblings. A value the aggregator produces, never parsed back out
    ## of a message string.
    seed*: uint64
    tracePath*: string
    case passed*: bool
    of true:
      discard
    of false:
      kind*: SimFailureKind
      msg*: string

proc runSweepSeed(seed: uint64, decisionBudget: int, timeBudget: Duration,
                   body: proc(): Future[void] {.gcsafe.}): SimSeedOutcome =
  ## One seed of a sweep, `simulate`'s failure-to-outcome conversion
  ## instead of a raised `SimulationError`: `collectSweepSeeds` is the
  ## loop this drives, one call per seed.
  try:
    runSimulation(seed, decisionBudget, timeBudget, enableLedger = false, body)
    SimSeedOutcome(seed: seed, tracePath: simTracePath(seed), passed: true)
  except SimulationError as exc:
    SimSeedOutcome(seed: seed, tracePath: exc.tracePath, passed: false,
                    kind: exc.kind, msg: exc.msg)

proc collectSweepSeeds*(seeds: Slice[uint64], decisionBudget: int,
                         timeBudget: Duration,
                         body: proc(): Future[void] {.gcsafe.}):
    seq[SimSeedOutcome] =
  ## The aggregation loop behind `sweepSeeds`/`sweepSeedsWithBudget`,
  ## exposed on its own (RFC 0003 3.8): runs `body` once per seed in
  ## `seeds`, every seed regardless of its siblings' outcomes, and
  ## returns every `SimSeedOutcome` in seed order. Unlike the
  ## `sweepSeeds` templates, this never touches `unittest2` - the
  ## aggregate verdict is the caller's to report however it chooses
  ## (`sweepSeeds` reports it the `checkLeaks` way; a caller wanting a
  ## different report, or none, calls this directly).
  for seed in seeds:
    result.add runSweepSeed(seed, decisionBudget, timeBudget, body)

proc reportSweep(outcomes: seq[SimSeedOutcome]) =
  ## The `checkLeaks` idiom (`chronos/unittest2/asynctests.nim`): a
  ## `checkpoint` per failing seed, so a green sweep of a hundred seeds
  ## stays quiet, and one `check` at the end so the enclosing test fails
  ## once - never once per seed - when any seed did (RFC 0003 3.8).
  var failedCount = 0
  for outcome in outcomes:
    if not outcome.passed:
      inc failedCount
      checkpoint "[chronos-sim] seed=0x" & toLowerAscii(toHex(outcome.seed)) &
        " FAILED (" & $outcome.kind & "): " & outcome.msg &
        " trace=" & outcome.tracePath
  check failedCount == 0

template sweepSeeds*(seeds: Slice[uint64], body: untyped): seq[SimSeedOutcome] =
  ## Runs `body` (async code, as `simulate`'s) once per seed in `seeds`
  ## on its own fresh hermetic sim dispatcher, collecting every seed's
  ## `SimSeedOutcome` and reporting the aggregate the `checkLeaks` way
  ## (RFC 0003 3.8): every failing seed's seed, kind, message, and trace
  ## path via `checkpoint`, then one `check` failing the enclosing test
  ## if any seed failed. See `sweepSeedsWithBudget` to override the
  ## per-seed budgets, and `collectSweepSeeds` to aggregate without the
  ## `unittest2` reporting.
  sweepSeedsWithBudget(seeds, simulateDefaultDecisionBudget,
                        simulateDefaultTimeBudget, body)

template sweepSeedsWithBudget*(seeds: Slice[uint64], decisionBudget: int,
                                timeBudget: Duration,
                                body: untyped): seq[SimSeedOutcome] =
  ## As `sweepSeeds`, with `decisionBudget`/`timeBudget` overriding the
  ## defaults for every seed in the sweep. A separate template rather
  ## than an overload of `sweepSeeds`, the same `await`-miscompiles
  ## reason `simulateWithBudget` is separate from `simulate`.
  let sweepOutcomes = collectSweepSeeds(seeds, decisionBudget, timeBudget,
    proc(): Future[void] {.async, gcsafe.} =
      body)
  reportSweep(sweepOutcomes)
  sweepOutcomes
