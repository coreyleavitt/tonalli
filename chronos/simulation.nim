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
## thread's real dispatcher afterward, whatever the body's outcome, plus
## its `simulateWith`/`simulateReplay`/`simulateReplayWith` siblings and
## the matching `sweepSeeds`/`sweepSeedsWith` pair - every one a fixed-
## arity template funneling into the same private `runSimulation` core,
## never an overload or a defaulted parameter (`simulateWith`'s
## docstring records why). Every optional knob (decision/time budget,
## ledger checking, a scripted oracle) is bundled into one `SimRunOptions`
## value built by `simOptions`, an ordinary proc that resolves its own
## defaults before a `simulateWith`/`simulateReplayWith`/`sweepSeedsWith`
## template call ever sees the result (R2-3's consolidation).
##
## Re-exports `chronos/internal/simengine` (which itself re-exports
## `chronos/internal/simtrace` and `chronos/internal/simledger`), so
## this is the one import a sim test needs beyond `chronos` itself:
## `SimOracle` and its choice-point/decision types, `newSimOracle`,
## `RandomOracle`, `ReplayOracle`, `SimBarrierError`, `SimEngineError`,
## `SimFailureKind`, `SimLedgerError`, and the trace schema.

import std/[deques, options, os, strutils, tables]
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
    ## two exceptions of its own, set here rather than carried on any
    ## raised exception: `BodyError` names "the failure was not one of
    ## the engine's own", and `BarrierHit` names a propagated or Defect-
    ## enveloped `SimBarrierError` - a hermeticity violation distinct
    ## from an ordinary body bug even though both surface through the
    ## body.
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

proc simTracePath*(seed: uint64): string =
  ## The formula this page documents (RFC 0003 3.8): `SimulationError.
  ## tracePath` already carries this for a failing run, and a caller
  ## needing a successful run's trace path too - `simulateReplay`'s own
  ## tests, replaying what a preceding `simulate(seed)` just recorded -
  ## has no other way to name it, since a clean `simulate` return
  ## carries no trace path of its own.
  getTempDir() / "chronos-sim" / ("seed-" & $seed & ".ndjson")

proc runSimulation(seed: uint64, decisionBudget: int, timeBudget: Duration,
                    enableLedger: bool, oracle: SimOracle,
                    body: proc(): Future[void] {.gcsafe.}) =
  ## The harness core every `simulate*` template funnels through (RFC
  ## 0003 3.8): saves the thread's current dispatcher without side
  ## effects, installs a fresh hermetic sim dispatcher driven by `oracle`
  ## and the given budgets, prints and flushes the seed banner, runs
  ## `body` to completion, and restores the saved dispatcher through the
  ## force path - unconditionally, whether `body` completed, the body
  ## raised, or the sim loop itself failed - so the original failure
  ## always survives and the calling thread's real dispatcher is always
  ## left intact. `oracle` is a caller-supplied parameter, not hardcoded:
  ## `simulate`/`simulateWith` (absent an `opts.oracle`) pass
  ## `RandomOracle(seed)`, `simulateWith(seed, simOptions(oracle = ...))`
  ## passes its caller's scripted oracle instead, `simulateReplay`/
  ## `simulateReplayWith` pass a `ReplayOracle` - every path through this
  ## proc gets the same restore/budget/trace/`SimulationError` guarantees
  ## regardless of which oracle drives it. `enableLedger` turns on the D8
  ## ghost-ledger laws (RFC 0003 3.9, slice S14); see
  ## `simulateWith(seed, simOptions(ledger = true))`. Stays private:
  ## every public entry point is one of the fixed-arity `simulate*`
  ## templates below, never a direct caller of this proc.
  let savedDisp = getThreadDispatcherOrNil()
  let tracePath = simTracePath(seed)
  createDir(tracePath.parentDir)
  var writer = openSimTraceWriter(tracePath, seed = seed,
    decisionBudget = decisionBudget,
    timeBudgetNanoseconds = timeBudget.nanoseconds)
  let timeBudgetCutoffNanoseconds =
    simClockAnchorNanoseconds + timeBudget.nanoseconds
  let disp = newSimDispatcher(oracle = oracle,
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
  except SimBarrierError as exc:
    # A provenance-guarded touch site the body reached, propagated
    # unchanged (`object of CatchableError`, deliberately not a subtype
    # of `AsyncError` - see its own docstring). A real hermeticity
    # violation - an un-barriered producer touching the sim dispatcher -
    # gets its own classification, `SimFailureKind.BarrierHit`, so a
    # sweep distinguishes it from the body's own ordinary bug by type,
    # never by parsing `exc.msg`.
    failure = newSimulationError(SimFailureKind.BarrierHit, seed, tracePath,
                                  exc.msg, exc)
  except CatchableError as exc:
    # Every other failure: from `runSimulation`'s perspective this is
    # the body's own logic at fault, `BodyError` naming "not one of the
    # engine's own typed failures, and not a barrier hit either".
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
      # As the direct-propagation `SimBarrierError` case above (`except
      # SimBarrierError`): a hermeticity violation, classified
      # `BarrierHit` regardless of which of the two paths (direct
      # propagation or this Defect envelope) carried it here.
      failure = newSimulationError(SimFailureKind.BarrierHit, seed,
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

template simulateCore(seed: uint64, decisionBudget: int, timeBudget: Duration,
                       enableLedger: bool, oracle: SimOracle,
                       body: untyped): untyped =
  ## Every `simulate*` template's sole path into `runSimulation`. Fixed
  ## arity, no defaulted parameter: a defaulted parameter here, relied
  ## on by omission at a call site, reproduces the same `await`-
  ## miscompiles-inside-`body` toolchain bug the module docstring
  ## records for same-named overloads (standalone-reproduced against
  ## the pinned Nim 2.2.10 toolchain: *any* omitted default ahead of a
  ## trailing `untyped` body parameter triggers it, not only two
  ## same-named templates) - which is why every public `simulate*`/
  ## `sweepSeeds*` template below has its own fixed arity instead of
  ## sharing one name with optional parameters.
  runSimulation(seed, decisionBudget, timeBudget, enableLedger, oracle,
    proc() {.async, gcsafe.} =
      body)

type
  SimRunOptions* = object
    ## Bundles `simulate()`'s optional knobs - decision/time budget,
    ## ledger checking, a caller-scripted oracle - into one value
    ## `simOptions` resolves (R2-3's consolidation): the family's only
    ## defaulted parameters live on that plain proc, never on a
    ## `simulateWith`/`simulateReplayWith`/`sweepSeedsWith` template
    ## itself (see `simulateWith`'s docstring for why). By the time a
    ## template call's `opts` argument is evaluated, every default is
    ## already resolved, so the template carries none of its own.
    ##
    ## Fields are private outside this module (R3-5): `simOptions` is
    ## the sole constructor, the same "construction discipline"
    ## `SimOracle`/`newSimOracle` already enforce
    ## (`chronos/internal/simengine.nim`) - a caller constructing a
    ## `SimRunOptions` literal directly (`SimRunOptions(decisionBudget:
    ## 500)`) would silently zero-fill every field it left out, most
    ## surprisingly `timeBudget`, tripping `TimeBudgetExhausted` on the
    ## first time advance instead of running under a real budget.
    ## `simulateWith`/`simulateReplayWith`/`sweepSeedsWith` stay able to
    ## read every field: privacy in Nim is module-scoped, not proc-
    ## scoped, and all three live in this same module.
    decisionBudget: int
    timeBudget: Duration
    ledger: bool
    oracle: Option[SimOracle]
      ## `none` (the default): the run is driven by `RandomOracle(seed)`
      ## (`simulateWith`), the trace's own `ReplayOracle`
      ## (`simulateReplayWith`), or one `RandomOracle(seed)` per seed
      ## (`sweepSeedsWith`) - the latter two refuse `some` outright (see
      ## their docstrings), since neither a replay nor a multi-seed sweep
      ## has one single oracle to hand it to. `some(oracle)`:
      ## `simulateWith` drives the run with `oracle` instead. Left
      ## `Option` rather than a bare `SimOracle`
      ## defaulted to `defaultSimOracle()`: `defaultSimOracle()` is
      ## itself a legitimate caller choice, so collapsing "the caller
      ## didn't ask" and "the caller asked for exactly the deterministic
      ## default" onto the same sentinel would be a silent correctness
      ## gap, not a simplification.

proc simOptions*(decisionBudget = simulateDefaultDecisionBudget,
                  timeBudget = simulateDefaultTimeBudget,
                  ledger = false,
                  oracle = none(SimOracle)): SimRunOptions =
  ## Resolves `simulateWith`/`simulateReplayWith`/`sweepSeedsWith`'s
  ## optional knobs into a `SimRunOptions` value. An ordinary proc, not a
  ## template or an overload of `simulate`: Nim resolves every default
  ## argument here, at this call, before the surrounding
  ## `simulateWith(seed, simOptions(...)): body` template call ever sees
  ## the result - the fixed-arity discipline every `simulate*`/
  ## `sweepSeeds*` template needs (`simulateWith`'s docstring) stays
  ## intact because the template's own `opts` parameter is never
  ## defaulted, only what built it. (Verified standalone before adoption:
  ## a fixed-arity template taking a pre-built options value plus a
  ## trailing `untyped` body, called both with an options argument that
  ## overrides one field and with a bare `simOptions()`, compiles and
  ## runs `await` inside `body` correctly against the pinned Nim 2.2.10
  ## toolchain - see the module docstring's toolchain-quirk note.)
  SimRunOptions(decisionBudget: decisionBudget, timeBudget: timeBudget,
                 ledger: ledger, oracle: oracle)

template simulate*(seed: uint64, body: untyped): untyped =
  ## Runs `body` (async code) to completion on a fresh, hermetic
  ## simulated dispatcher driven by `RandomOracle(seed)`, then restores
  ## the calling thread's real dispatcher - even if `body` raises or
  ## the simulation itself fails. A run that exceeds the default
  ## decision/time budget (RFC 0003 3.8), deadlocks, or hits an oracle/
  ## protocol violation raises `SimulationError`, and so does a raising
  ## `body` (unwrapped as `.parent`). See `simulateWith` to override the
  ## budgets, check RFC 0003 3.9's ghost-ledger conservation laws, or
  ## drive the run with a scripted oracle, in any combination, and
  ## `simulateReplay`/`simulateReplayWith` to replay a recorded trace.
  let seedOnce = seed
  simulateCore(seedOnce, simulateDefaultDecisionBudget,
    simulateDefaultTimeBudget, false, RandomOracle(seedOnce), body)

template simulateWith*(seed: uint64, opts: SimRunOptions,
                        body: untyped): untyped =
  ## As `simulate`, with every optional knob `opts` (`simOptions`)
  ## carries: `decisionBudget`/`timeBudget` override the defaults (the
  ## bounds a livelock trips at, RFC 0003 3.8), `ledger` additionally
  ## checks RFC 0003 3.9's ghost-ledger conservation laws (callback
  ## conservation, future lifecycle, and more) at every step boundary
  ## and at teardown, raising `SimLedgerError` (distinct by type from
  ## `SimulationError`) on a violation, and `oracle`, if `some`, drives
  ## the run with a caller-scripted `SimOracle` (`newSimOracle`) instead
  ## of `RandomOracle(seed)` - the harness-level escape hatch for a test
  ## that scripts a specific interleaving or fault, still getting every
  ## harness guarantee (restore-on-any-outcome, decision/time budgets,
  ## trace recording, typed `SimulationError` classification) instead of
  ## hand-rolling a throwaway `newSimDispatcher`/`setThreadDispatcher`
  ## pair on its own thread and losing all of them. With `opts.oracle`
  ## set, `seed` no longer drives any decision - the scripted oracle
  ## owns every one - and only selects the trace path
  ## (`simTracePath(seed)`) and the seed a `SimulationError` attributes
  ## the run to; two scripted-oracle tests sharing a seed share a trace
  ## file, so pick distinct seeds to keep each test's trace separate.
  ## One template, not an overload of `simulate` sharing its name: on
  ## the pinned Nim 2.2.10 toolchain, both a same-named overload and
  ## *any* defaulted parameter ahead of a trailing `untyped` body
  ## miscompile `await` inside `body`
  ## the moment a caller omits it (standalone-reproduced, not specific to
  ## this module) - which is why `opts` is a single pre-resolved value
  ## from `simOptions` (an ordinary proc, defaults and all) rather than
  ## `simulateWith` carrying `decisionBudget`/`timeBudget`/`ledger`/
  ## `oracle` as defaulted parameters of its own. `seed` and `opts` are
  ## each evaluated exactly once, regardless of `body`.
  let seedOnce = seed
  let optsOnce = opts
  let oracleOnce =
    if optsOnce.oracle.isSome: optsOnce.oracle.get()
    else: RandomOracle(seedOnce)
  simulateCore(seedOnce, optsOnce.decisionBudget, optsOnce.timeBudget,
    optsOnce.ledger, oracleOnce, body)

template simulateReplay*(tracePath: string, body: untyped): untyped =
  ## Replays a previously recorded trace (RFC 0003 3.8's sketch): drives
  ## the same harness `simulate` does, over a `ReplayOracle` built from
  ## the trace at `tracePath`, in place of `RandomOracle(seed)`,
  ## attributed to the seed recorded in the trace's own header - a
  ## replay has no seed of its own to offer, and the header's is the
  ## only honest answer (RFC 0003 3.7's header already carries it for
  ## exactly this kind of attribution). The decision/time budgets default
  ## to the ones *recorded in the trace's own header* (R2-4), not this
  ## module's global defaults: a trace recorded under a tighter budget
  ## replays under that same tighter budget, so a run that failed by
  ## exhausting its budget still fails the same way on replay
  ## (`SimulationError.kind == DecisionBudgetExhausted`/
  ## `TimeBudgetExhausted`) instead of running past where the recording
  ## stopped and misreporting a replay-exhausted `ProtocolViolation` once
  ## the recorded decisions run out. See `simulateReplayWith` to override
  ## the budgets, or check ghost-ledger laws, during a replay. Reads and
  ## parses `tracePath` exactly once, for the attribution, the budgets,
  ## and the oracle alike.
  let trace = readSimTrace(tracePath)
  simulateCore(trace.header.seed, trace.header.decisionBudget,
    nanoseconds(trace.header.timeBudgetNanoseconds), false,
    ReplayOracle(trace.records), body)

template simulateReplayWith*(tracePath: string, opts: SimRunOptions,
                              body: untyped): untyped =
  ## As `simulateReplay`, with `opts.decisionBudget`/`opts.timeBudget`/
  ## `opts.ledger` (`simOptions`) overriding what would otherwise default
  ## to the trace header's own recorded budgets - an explicit `opts`
  ## always wins, the same "caller asked, caller gets it" rule
  ## `simulateWith` follows for a live run. `opts.oracle` must be `none`:
  ## a replay always drives the run from the trace's own `ReplayOracle`,
  ## never a caller-supplied one, so a `some` here is refused with a
  ## `doAssert` rather than silently ignored - a scripted oracle and
  ## deterministic replay are two different, mutually exclusive ways of
  ## resolving the same choice points. `tracePath` and `opts` are each
  ## evaluated exactly once.
  let trace = readSimTrace(tracePath)
  let optsOnce = opts
  doAssert optsOnce.oracle.isNone,
    "simulateReplayWith(): opts.oracle must be unset - a replay always " &
    "drives the run from the trace's own ReplayOracle"
  simulateCore(trace.header.seed, optsOnce.decisionBudget,
    optsOnce.timeBudget, optsOnce.ledger, ReplayOracle(trace.records), body)

proc simLedgerDebugPlantDroppedEnqueue*(kind: SimLedgerQueueKind) =
  ## TEST-ONLY escape hatch (RFC 0003 slice S14's RED phase): records
  ## an `enqueue` the ledger will never observe a matching `fired`/
  ## `nilPop`/still-queued for, planting the callback-conservation
  ## law's "dropped callback" violation - the #703 bug class (a queued
  ## callback surviving the frame that owns its captured state)
  ## caught structurally, without needing an actual crash to
  ## reproduce it. Requires a currently-running `simulateWith(ledger = true)`
  ## body; not part of the stable API.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugPlantDroppedEnqueue() requires simulateWith(ledger = true)"
  ledger.noteEnqueue(kind)

proc simLedgerDebugCurrentStep*(): int =
  ## TEST-ONLY (RFC 0003 slice S14): the ledger's current step index -
  ## `tests/testsimledger.nim` uses this to pin that a synchronous
  ## cancellation cascade does not advance it (3.9: cascades account to
  ## the enclosing step). Requires a currently-running
  ## `simulateWith(ledger = true)` body; not part of the stable API.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugCurrentStep() requires simulateWith(ledger = true)"
  ledger.currentStep()

proc simLedgerDebugNilPopCount*(kind: SimLedgerQueueKind): uint64 =
  ## TEST-ONLY (RFC 0003 slice S14): see `simLedgerDebugCurrentStep`.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugNilPopCount() requires simulateWith(ledger = true)"
  ledger.nilPopCount(kind)

proc simLedgerDebugPlantContextImbalance*() =
  ## TEST-ONLY escape hatch (RFC 0003 slice S15's RED phase), the
  ## contextvar-conservation analogue of
  ## `simLedgerDebugPlantDroppedEnqueue`: records a `captured` the
  ## ledger will never observe a matching `restored`/still-resident for,
  ## planting the "capture and restore balance across every scheduling
  ## point" law's violation without needing a genuine capture/restore
  ## bug to reproduce it. Requires a currently-running
  ## `simulateWith(ledger = true)` body; not part of the stable API.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugPlantContextImbalance() requires simulateWith(ledger = true)"
  ledger.noteContextCaptured()

proc simLedgerDebugPlantTimerImbalance*() =
  ## TEST-ONLY escape hatch (RFC 0003 slice S15's RED phase), the timer-
  ## accounting analogue of `simLedgerDebugPlantDroppedEnqueue`: records
  ## an `armed` the ledger will never observe a matching `fired`/
  ## `cancelled`/still-pending for. Requires a currently-running
  ## `simulateWith(ledger = true)` body; not part of the stable API.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerDebugPlantTimerImbalance() requires simulateWith(ledger = true)"
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
  ## running `simulateWith(ledger = true)` body.
  let loop = getThreadDispatcher()
  let ledger = loop.simLedgerOf()
  doAssert not ledger.isNil,
    "simLedgerRegisterWaiter() requires simulateWith(ledger = true)"
  ledger.registerWaiterPrimitive(desc, countProc)

proc simLedgerTrackWaiters*(lock: AsyncLock) =
  ## Opts `lock` into waiter conservation (RFC 0003 3.9's 2026-08-15
  ## amendment). Call once per instance, after construction, from
  ## inside a `simulateWith(ledger = true)` body.
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
  SimSeedFailureKind* {.pure.} = enum
    ## Distinguishes a failing `SimSeedOutcome` by type (RFC 0003 3.9's
    ## "a test distinguishes a ledger violation ... by type, never by
    ## string-matching the message", applied to this aggregated value
    ## the same way a raised `SimulationError`/`SimLedgerError` already
    ## is): `Engine` is a `SimulationError`-shaped failure - a livelock,
    ## a deadlock, an oracle/protocol violation, a barrier hit, or the
    ## body's own exception, `kind` naming which; `Ledger` is a
    ## `SimLedgerError`, kept a separate case rather than folded into
    ## `SimFailureKind`, the same separation `SimLedgerError`'s own
    ## docstring requires of a raised failure.
    Engine
    Ledger

  SimSeedOutcome* = object
    ## One seed's verdict from `sweepSeeds`/`collectSweepSeeds` (RFC 0003
    ## 3.8): every seed in the swept range gets exactly one of these, in
    ## seed order, whether it passed or failed - the sweep never stops
    ## at the first failure, so a multi-seed bug never hides its
    ## siblings. A value the aggregator produces, never parsed back out
    ## of a message string. `kind` (RFC 0003 R3-6) is nested under the
    ## `Engine` arm of `failureKind`'s own case, rather than sitting
    ## beside it with a prose-only "meaningful only when Engine" caveat:
    ## a `Ledger` failure has no `SimFailureKind` of its own to report,
    ## and a wrong-branch access now raises `FieldDefect` at the read
    ## instead of returning a stale zero value guarded only by prose.
    seed*: uint64
    tracePath*: string
    case passed*: bool
    of true:
      discard
    of false:
      msg*: string
      case failureKind*: SimSeedFailureKind
      of SimSeedFailureKind.Engine:
        kind*: SimFailureKind
      of SimSeedFailureKind.Ledger:
        discard

proc runSweepSeed(seed: uint64, decisionBudget: int, timeBudget: Duration,
                   enableLedger: bool,
                   body: proc(): Future[void] {.gcsafe.}): SimSeedOutcome =
  ## One seed of a sweep, `simulate`'s failure-to-outcome conversion
  ## instead of a raised `SimulationError`/`SimLedgerError`:
  ## `collectSweepSeeds` is the loop this drives, one call per seed. A
  ## planted ledger violation is this seed's `SimSeedOutcome` failure,
  ## not a process-ending raise - the same "every seed runs regardless
  ## of its siblings" guarantee `SimulationError` already gets, extended
  ## to the ledger's distinct exception type.
  try:
    runSimulation(seed, decisionBudget, timeBudget, enableLedger,
                  RandomOracle(seed), body)
    SimSeedOutcome(seed: seed, tracePath: simTracePath(seed), passed: true)
  except SimulationError as exc:
    SimSeedOutcome(seed: seed, tracePath: exc.tracePath, passed: false,
                    failureKind: SimSeedFailureKind.Engine, kind: exc.kind,
                    msg: exc.msg)
  except SimLedgerError as exc:
    SimSeedOutcome(seed: seed, tracePath: simTracePath(seed), passed: false,
                    failureKind: SimSeedFailureKind.Ledger, msg: exc.msg)

proc collectSweepSeeds*(seeds: Slice[uint64], decisionBudget: int,
                         timeBudget: Duration,
                         body: proc(): Future[void] {.gcsafe.},
                         ledger: bool = false):
    seq[SimSeedOutcome] =
  ## The aggregation loop behind `sweepSeeds`/`sweepSeedsWith`, exposed
  ## on its own (RFC 0003 3.8): runs `body` once per seed in `seeds`,
  ## every seed regardless of its siblings' outcomes, and returns every
  ## `SimSeedOutcome` in seed order. `ledger` (default `false`, so
  ## every pre-existing caller is unaffected) turns on the D8 ghost-
  ## ledger laws for every seed in the sweep, the same flag
  ## `simulateWith(seed, simOptions(ledger = true))` threads through the
  ## single-run harness. Unlike the `sweepSeeds` templates, this never
  ## touches `unittest2` - the aggregate verdict is the caller's to
  ## report however it chooses (`sweepSeeds` reports it the `checkLeaks`
  ## way; a caller wanting a different report, or none, calls this
  ## directly).
  for seed in seeds:
    result.add runSweepSeed(seed, decisionBudget, timeBudget, ledger,
                             body)

proc reportSweep(outcomes: seq[SimSeedOutcome]) =
  ## The `checkLeaks` idiom (`chronos/unittest2/asynctests.nim`): a
  ## `checkpoint` per failing seed, so a green sweep of a hundred seeds
  ## stays quiet, and one `check` at the end so the enclosing test fails
  ## once - never once per seed - when any seed did (RFC 0003 3.8).
  var failedCount = 0
  for outcome in outcomes:
    if not outcome.passed:
      inc failedCount
      let kindDesc = case outcome.failureKind
        of SimSeedFailureKind.Engine: $outcome.kind
        of SimSeedFailureKind.Ledger: "LedgerViolation"
      checkpoint "[chronos-sim] seed=0x" & toLowerAscii(toHex(outcome.seed)) &
        " FAILED (" & kindDesc & "): " & outcome.msg &
        " trace=" & outcome.tracePath
  check failedCount == 0

template sweepSeedsCore(seeds: Slice[uint64], decisionBudget: int,
                         timeBudget: Duration, enableLedger: bool,
                         body: untyped): seq[SimSeedOutcome] =
  ## Every `sweepSeeds*` template's sole path into `collectSweepSeeds`/
  ## `reportSweep` - fixed arity, no defaulted parameter, the same
  ## reason `simulateCore` is (see its docstring).
  let sweepOutcomes = collectSweepSeeds(seeds, decisionBudget, timeBudget,
    proc(): Future[void] {.async, gcsafe.} =
      body,
    enableLedger)
  reportSweep(sweepOutcomes)
  sweepOutcomes

template sweepSeeds*(seeds: Slice[uint64], body: untyped): seq[SimSeedOutcome] =
  ## Runs `body` (async code, as `simulate`'s) once per seed in `seeds`
  ## on its own fresh hermetic sim dispatcher, collecting every seed's
  ## `SimSeedOutcome` and reporting the aggregate the `checkLeaks` way
  ## (RFC 0003 3.8): every failing seed's seed, kind, message, and trace
  ## path via `checkpoint`, then one `check` failing the enclosing test
  ## if any seed failed. See `sweepSeedsWith` to override the per-seed
  ## budgets or additionally check RFC 0003 3.9's ghost-ledger
  ## conservation laws over every seed in the sweep, and
  ## `collectSweepSeeds` to aggregate without the `unittest2` reporting.
  sweepSeedsCore(seeds, simulateDefaultDecisionBudget,
                 simulateDefaultTimeBudget, false, body)

template sweepSeedsWith*(seeds: Slice[uint64], opts: SimRunOptions,
                          body: untyped): seq[SimSeedOutcome] =
  ## As `sweepSeeds`, with `opts.decisionBudget`/`opts.timeBudget`
  ## (`simOptions`) overriding the defaults, and `opts.ledger`
  ## additionally checking RFC 0003 3.9's ghost-ledger conservation laws,
  ## for every seed in the sweep - the same knobs `simulateWith` applies
  ## to a single run. A violating seed's `SimSeedOutcome` reports
  ## `failureKind == SimSeedFailureKind.Ledger`; a non-violating seed
  ## passes exactly as it would under `sweepSeeds`. `opts.oracle` must be
  ## `none`: each seed in a sweep drives its own `RandomOracle(seed)`, so
  ## a single caller-supplied oracle shared across every seed is not a
  ## meaningful request - refused with a `doAssert` rather than silently
  ## ignored, the same discipline `simulateReplayWith` applies to its own
  ## oracle field. `opts` is evaluated exactly once.
  let optsOnce = opts
  doAssert optsOnce.oracle.isNone,
    "sweepSeedsWith(): opts.oracle must be unset - each seed in a sweep " &
    "drives its own RandomOracle(seed), never a single shared oracle"
  sweepSeedsCore(seeds, optsOnce.decisionBudget, optsOnce.timeBudget,
                 optsOnce.ledger, body)
