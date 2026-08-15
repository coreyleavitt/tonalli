# Deterministic simulation

The simulation substrate lets a test run chronos's event loop over a
seeded, injectable source of nondeterminism instead of the real clock,
selector, and network stack. A failing interleaving becomes a seed: one
number that reproduces the same run, in milliseconds, on any machine,
instead of an intermittent CI flake that takes days to corner.

<!-- toc -->

> **Fork-only, experimental API.** This substrate is not part of
> upstream chronos and is not intended to be upstreamed: it is
> infrastructure for testing chronos itself and the projects built on
> this fork, gated entirely behind the `chronosSimulation` define. With
> the define undefined, none of it exists in a compiled binary --
> `chronos.nim`'s export surface, every real-mode call site, and every
> benchmark are unaffected (see [Performance](#performance)). With the
> define on, the API is still young: it grew slice by slice against the
> tests that needed it (RFC 0003), several corners named throughout this
> page are honest gaps rather than oversights, and shapes here can still
> change between fork releases without a deprecation cycle. Nothing here
> is a stability promise the way the rest of this book's user guide is.

## Usage

```nim
import chronos
import chronos/simulation

test "a byte written on one side of a sim pair reaches the other":
  simulate(seed = 1'u64):
    let net = simNet()
    let server = net.listenStream(initTAddress("127.0.0.1:1"))
    let clientFut = net.connectStream(initTAddress("127.0.0.1:1"))
    let serverSide = await server.accept()
    let client = await clientFut
    discard await client.write(@[1'u8, 2, 3])
    var buf: array[3, byte]
    await serverSide.readExactly(addr buf[0], 3)
    check buf == [1'u8, 2, 3]
```

`readExactly`, not a single `read`, is deliberate here: `RandomOracle`
can complete `write`/`read` short (the same sim analogue of a real
partial socket operation `decideIo` models, see
[Oracles](#oracles)), so a fixed seed's single `read` call is not
guaranteed to return all three bytes in one step. `readExactly` already
retries until it has what it asked for, the same as it does against a
real socket, so the example holds for any seed. This is also why the
top-level example above uses a stream pair rather than a datagram pair:
a live datagram endpoint's write can draw a partial byte count under
`RandomOracle` too, a recorded gap ([Faults](#faults)'s neighboring
section notes it), and unlike a stream read there is no `readExactly`
equivalent for a message-oriented datagram - a short datagram read is
simply a truncated message, matching what a real `recvfrom()` into an
undersized buffer would do.

A `simulate` body is ordinary async chronos code: `await`, combinators,
`AsyncQueue`/`AsyncLock`/etc. (see [Surfaces that need no
seam](#surfaces-that-need-no-seam)), and any transport built on top of a
`SimNet` endpoint all work unmodified. What changes underneath is where
nondeterminism comes from: the clock, the readiness/arrival delivery
order, and I/O outcomes are all decided by an oracle instead of the real
OS, and every decision is logged.

## `simulate`, `simulateWithBudget`, `simulateWithLedger`

```nim
template simulate*(seed: uint64, body: untyped): untyped
template simulateWithBudget*(seed: uint64, decisionBudget: int,
                              timeBudget: Duration, body: untyped): untyped
template simulateWithLedger*(seed: uint64, body: untyped): untyped
```

`simulate` runs `body` to completion on a fresh, hermetic simulated
dispatcher driven by `RandomOracle(seed)`, then restores the calling
thread's real dispatcher, whether `body` completed, raised, or the
simulation itself failed. It nests inside an existing `test`/`asyncTest`
block, or runs bare in a script to replay one seed's trace by hand.

Every run carries a decision budget (`simulateDefaultDecisionBudget`,
10 000: every oracle `decide*` call counts, which also bounds a
partial-write retry spin inside one callback) and a virtual-time budget
(`simulateDefaultTimeBudget`, one hour of virtual time). Exhausting
either is a distinct, named failure ("livelock: decision budget
exhausted..." / "livelock: virtual-time budget exhausted..."), separate
from quiescence deadlock ("deadlock: no runnable work" -- a body
awaiting a future nothing will ever complete). `simulateWithBudget`
overrides both defaults for one run; it is a separate template rather
than an overload of `simulate` because the two sharing a name
miscompiles `await` inside `body` on the pinned Nim 2.2.10 toolchain (a
standalone-reproduced compiler quirk, not a design choice).

A failing run raises `SimulationError`, carrying `kind: SimFailureKind`
(`BodyError`, `Deadlock`, `OracleDeferral`, `ProtocolViolation`,
`DecisionBudgetExhausted`, `TimeBudgetExhausted`), `seed`, and
`tracePath` -- the decision log's path under
`getTempDir() / "chronos-sim" / "seed-<seed>.ndjson"`. A raising body's
own exception is unwrapped as `.parent`. The seed banner
(`[chronos-sim] seed=... trace=...`) is written and flushed before the
body runs, so even a process-fatal `Defect` escaping a run is
attributable to its seed from stray output alone.

`simulateWithLedger` additionally checks the D8 ghost-ledger
conservation laws (callback, future, contextvar, timer, and waiter
conservation -- see [Ghost ledgers](#ghost-ledgers)) at every step
boundary and at teardown. A violation raises `SimLedgerError`, a
distinct type from `SimulationError`, so a caller distinguishes a
ledger violation from a body failure, an oracle error, or a barrier hit
by type, never by string-matching a message. It is a separate entry
point, not a flag on `simulate`, because ledger checking depends on
instrumentation coverage that is not exhaustive over every producer in
the codebase (see [Ghost ledgers](#ghost-ledgers)); every pre-existing
`simulate`/`sweepSeeds` caller is unaffected by construction.

## `sweepSeeds`

```nim
template sweepSeeds*(seeds: Slice[uint64], body: untyped): seq[SimSeedOutcome]
template sweepSeedsWithBudget*(seeds: Slice[uint64], decisionBudget: int,
                                timeBudget: Duration,
                                body: untyped): seq[SimSeedOutcome]
proc collectSweepSeeds*(seeds: Slice[uint64], decisionBudget: int,
                         timeBudget: Duration,
                         body: proc(): Future[void] {.gcsafe.}):
    seq[SimSeedOutcome]
```

`sweepSeeds` runs `body` once per seed in `seeds`, each on its own fresh
hermetic dispatcher, and reports the aggregate the way
`unittest2`/`asynctests.nim`'s `checkLeaks` idiom does: a `checkpoint`
per failing seed (seed, kind, message, trace path), so a green sweep of
a hundred seeds stays quiet, then one `check` at the end that fails the
enclosing test once -- never once per seed -- if any seed did. Every
seed in the range runs regardless of its siblings' outcomes, so a
multi-seed bug never hides behind the first failure.

`SimSeedOutcome` is a plain value the sweep produces, never parsed back
out of a message string:

```nim
type
  SimSeedOutcome* = object
    seed*: uint64
    tracePath*: string
    case passed*: bool
    of true: discard
    of false:
      kind*: SimFailureKind
      msg*: string
```

`collectSweepSeeds` is the aggregation loop on its own, with no
`unittest2` dependency, for a caller that wants the raw outcomes without
`sweepSeeds`'s own reporting (or a different report entirely).

## Oracles

```nim
proc RandomOracle*(seed: uint64): SimOracle
proc newSimOracle*(decideBatch: proc(cp: SelectBatchPoint): ...,
                    decideIo: proc(cp: IoOutcomePoint): ...,
                    decideTime: proc(cp: TimeAdvancePoint): ...): SimOracle
proc ReplayOracle*(path: string): SimOracle
```

An oracle answers exactly three choice points -- `decideBatch` (which
pending readiness/arrival events to deliver, and in what order),
`decideIo` (how one I/O operation resolves: full, partial, or a fault),
and `decideTime` (how far to advance the virtual clock when nothing else
is runnable) -- through `newSimOracle`'s constructor, the only way to
build a `SimOracle`: partial construction would let an older wrapper
compile with a new choice point silently nil, crashing at the first call
instead of failing per-seed, so the constructor forces every field
explicit.

**`RandomOracle(seed)`** is what `simulate`/`sweepSeeds` use: the same
seed produces the same decisions on every run (a self-contained
`splitmix64` generator, never `std/random`'s global state). It shuffles
deliverable events into a random legal order, draws a uniform byte count
in `1..maxBytes` for `decideIo` (full completion is one of the possible
draws, not a separate case), and advances to the earliest armed deadline
for `decideTime` -- randomizing among armed deadlines, or synthesizing
faults, is exploration-oracle territory (tracker issue #10), out of
scope here.

**A scripted oracle** is any `SimOracle` built from hand-written
closures, typically fixing two of the three choice points to
`defaultDecideBatch`/`defaultDecideIo`/`defaultDecideTime` (each
exported for exactly this reuse) and overriding the third to script a
specific interleaving or fault. This is how the sim substrate's own
test suite exercises slices ahead of a live producer, and how a test
targeting one specific bug (a reset at a specific point in a stream, an
out-of-order datagram) scripts the exact conditions that reproduce it,
without waiting on `RandomOracle` to find them by chance.

**`ReplayOracle(path)`**, constructed from a recorded trace, verifies
each live choice point's digest against the next recorded one (the
`digestOf` function shared with the trace writer, so "digest mismatch"
cannot mean two different things between the two) and returns the
recorded decision. A version-mismatched trace is refused at
construction; a live digest diverging from the recording surfaces as a
structured `SimOracleError` carrying the expected and actual digest,
never a silent wrong decision. **Current state, recorded honestly:**
`ReplayOracle` is fully built and tested against `SimEngineState`
directly (see `tests/testsimoracle.nim`'s "sim ReplayOracle" suite), but
the convenience harness entry point sketched in RFC 0003 section 3.8
(`simulateReplay(path): body`, wiring a `ReplayOracle` through
`simulate`'s own save/restore machinery) does not exist yet as of this
page: `chronos/simulation.nim`'s `runSimulation` always constructs
`RandomOracle(seed)` internally, with no oracle parameter exposed.
Replaying a recorded trace today means driving `ReplayOracle` against
the lower-level engine the way the test suite does, not a one-line
`simulate` call; closing that gap is unclaimed follow-on work, not part
of this page's claims about what ships.

## `SimNet` and datagram pairs

```nim
proc simNet*(): SimNet
proc listenStream*(net: SimNet, address: TransportAddress): SimStreamServer
proc accept*(server: SimStreamServer): Future[StreamTransport]
proc connectStream*(net: SimNet, address: TransportAddress): Future[StreamTransport]
proc datagramPair*(net: SimNet, addrA, addrB: TransportAddress,
                    cbprocA, cbprocB: DatagramCallback,
                    udataA: pointer = nil, udataB: pointer = nil):
    tuple[a, b: DatagramTransport]
```

`simNet()` attaches to the current run's sim network -- one per sim
dispatcher, so every call against the same run's dispatcher sees the
same listener bindings. Connection establishment is sim-native, not
seamed: `listenStream`/`connectStream` mint an already-connected
`StreamTransport` pair directly, so the real accept/connect/shutdown
state machines are never exercised under simulation, a recorded
coverage concession (RFC 0003 section 4). What *is* exercised, and
proven identical to a real transport pair over the same body
(`tests/testsimnet.nim`'s differential echo test), is everything above
that seam: the `BipBuffer`, the vector write queue, and the transport
state machine, including half-close (`closeWait`/`shutdownWait`
deliver EOF to the peer, the same `res == 0` convention a real socket
read uses).

`datagramPair` is the connectionless analogue: UDP has no handshake to
mint sim-natively, so both sides of a pair are wired atomically in one
call rather than a listener/dialer pair like the stream case.

**POSIX only in this slice.** Both the stream and datagram surfaces
build on seams (`chronos/transports/stream.nim`'s and `datagram.nim`'s
raw I/O extraction) that exist only in each module's POSIX branch,
matching RFC section 4's Windows IOCP-emulation non-goal. On Windows,
`listenStream`/`connectStream`/`accept`/`datagramPair` compile and
type-check (satisfying `nimble check_windows`) but `raiseAssert` if
ever reached at runtime, naming the non-goal in the message rather than
silently doing nothing.

## `simProducer`: arrival actors without threads

```nim
proc simProducer*(): SimProducer
proc post*(producer: SimProducer, cbproc: ThreadCallbackFunc, udata: pointer = nil)
```

A real cross-thread `callSoon` reaches a dispatcher through
`DispatcherHandle`, and both `wake()` and minting a `DispatcherHandle`
barrier under simulation (see [Barrier list](#barrier-list)) --
`simProducer()` is the sim-legal replacement, not a supplement. A
`post()` call schedules `cbproc` for cross-thread-style delivery: it
fires with `bareCallback` semantics (no captured continuation-local
context), the same as a genuine cross-thread arrival, through the
unmodified real drain path (`processThreadCallbacks`) over a simulated
MPSC queue. The `hasThreadSupport` machinery this runs on exists only
under `--threads:on`, matching real cross-thread `callSoon`'s own
precondition.

Posts are coalesced the same way the real wakeup protocol coalesces
them: every post landing between two drains lands in one delivered
`Arrival` event, and the oracle cannot split them into a schedule the
real system could never produce. This is what makes `simProducer` able
to reproduce genuine arrival-interleaving races (a callback outliving
the frame that owned its captured state -- upstream issue #694's class)
at poll-iteration granularity; it does not model the waking-flag
protocol's own memory-order interleavings inside `mpsc.nim`, which is
out of scope for an input-level simulator (RFC 0003 section 3.6).

## Faults

```nim
type SimFault* {.pure.} = enum
  Reset
  Drop
  Duplicate
  Reorder
```

A scripted `decideIo` closure returns a fault instead of an `Ok`
outcome to inject one of these into a live `SimNet` endpoint's I/O:

- **`Reset`** is a recv-side fault, legal on both stream and datagram
  reads: the local read fails with the same `OSErrorCode` a real
  platform's ECONNRESET-after-ICMP-unreachable would surface
  (`simFaultToError`), reached through the exact same
  `isConnResetError`/`setReadError`/`handleError` path a real error
  takes.
- **`Drop`**, **`Duplicate`**, and **`Reorder`** are datagram-only,
  write-side faults: real UDP never fails a send over packet loss, so
  each is intercepted by name in `simDatagramIo`'s write branch before
  it would otherwise need an `OSErrorCode` translation (`Reset` is the
  only member `simFaultToError` actually translates; the other three
  raise if ever routed there, a deliberate "should never reach this"
  guard). `Drop` silently discards the message after the local send
  still succeeds; `Duplicate` delivers it to the peer twice;
  `Reorder` delivers it ahead of whatever the peer already had queued
  (a no-op back-of-queue delivery if nothing was pending yet).

Every `IoOutcomePoint` carries the legal fault set for that specific
operation (`{}` for a stream write, `{Reset}` for a datagram read,
`{Drop, Duplicate, Reorder}` for a datagram write, and so on), so a
scripted oracle only ever needs to handle the faults that operation can
actually raise.

## Ghost ledgers

Ghost ledgers (RFC 0003 section 3.9) are simulation-only conservation
checks, opt-in via `simulateWithLedger`: every quantity they track
either balances exactly, or the run fails loudly with the seed, a step
index, and the specific object involved -- never a silent pass that
only happened to avoid the bug this run.

| law | conserved quantity | checked |
|---|---|---|
| callback conservation | enqueued = fired + explicitly dropped at teardown + nil-function pops, per queue (`Callbacks`/`Idlers`/`Ticks`) | every step boundary, and teardown |
| future lifecycle | no future completes twice (identity-based, via `chronosFutureTracking`) | every terminal transition |
| contextvar accounting | captured = restored + still-queued-with-context | `simulate()` teardown |
| timer accounting | armed = fired + cancelled + pending (against the timer heap's own contents) | every step boundary, and teardown |
| waiter conservation | every tracked primitive's live waiter count is zero | `simulate()` teardown |

A step is one outermost `fireWithContext` return; a reentrant `waitFor`
inside a firing callback opens its own nested step that accounts to the
enclosing one, never advancing the step index itself, and a synchronous
cancellation cascade (`tryCancel` recursing through child futures)
accounts to whichever step triggered it. A violation raises
`SimLedgerError{seed, step, objectDesc}`, its message prefixed
`"simulation invariant violation: "`, naming the law and the object,
never the internal "ghost ledger" codename.

**Contextvar and timer accounting** are checked the same way callback
conservation is: real hooks at the real capture/restore and
arm/fire/cancel touchpoints in `asyncengine.nim`, independent counters
that can only diverge if a real code path bypasses one of them.
Contextvar accounting is evaluated only at teardown, not per-fire, for
an interface reason rather than a design one: `DispatcherBase.callbacks`
is a `CallbackQueue` (`chronos/internal/callbackqueue.nim`) whose public
interface is deliberately exactly five entry points with no iteration
or random access, so there is no cheap way to read "how many queued
callbacks carry a context" at an arbitrary mid-run checkpoint. Teardown
already walks every resident callback via the queue's own `popFirst` for
the callback-conservation check, so inspecting each one's context there
is free; timer accounting has no such constraint (the timer heap's
length is O(1)) and is checked on every fire.

**Waiter conservation** (added 2026-08-15, issue #9) is different in
kind from the other four: `chronos/asyncsync.nim` gains no seam for it
at all. `AsyncLock`, `AsyncEvent`, `AsyncQueue`, `AsyncEventQueue`, and
`AsyncSemaphore` are unmodified except for read-only accessors
(`waitersCount`/`gettersCount`/`puttersCount`, from
`feat/asyncsync-waiters-introspection`, plus this page's own
`AsyncEventQueue.waitersCount` in the same style), each reporting how
many futures are currently parked and not cancelled. A test opts a
constructed primitive into the law explicitly:

```nim
simulateWithLedger(seed = 0xC0FFEE'u64):
  let lock = newAsyncLock()
  simLedgerTrackWaiters(lock)
  ...
```

`simLedgerTrackWaiters` has an overload per primitive kind
(`AsyncLock`, `AsyncEvent`, `AsyncQueue[T]` -- registering `getters` and
`putters` as two separately-named lists -- `AsyncEventQueue[T]`, and
`AsyncSemaphore`); `simLedgerRegisterWaiter(desc, countProc)` is the
generic entry point underneath, for a primitive shape none of those
overloads cover. This registration is test-side by design: the
alternatives (a hook at construction, or a hook inside
`acquire`/`release`/`wait`/etc.) would both require the seam the law is
explicitly built to avoid, and test-side registration costs nothing for
every caller that never uses it, matching the same opt-in discipline
every other ledger law already follows.

The law's only enforcement point is teardown, not every step boundary,
which is a deliberate, recorded judgment call: a registered primitive's
accessor reading "currently parked" is completely ordinary mid-run --
most programs have another task legitimately waiting on a lock or a
queue slot at any given moment -- so nothing short of the run actually
ending can tell a legitimate in-flight wait apart from a leak. What the
teardown reading catches is exactly the motivating case: a
`race()`/`one()`-style abandoned wait. `race`/`one` complete on the
first future to finish and only `removeCallback` the others -- they
document that losing futures are never cancelled -- so a losing
`AsyncLock.acquire()` (or any other primitive's wait) stays parked in
its waiter list forever, neither woken nor cancelled, invisible to
every other check in this table. A nonzero reading at teardown names
exactly that primitive.

## Barrier list

Reached with a real fd, or from an API that inherently touches real OS
resources, a provenance-guarded call fails loudly and catchably instead
of touching a nil selector or a zero-initialized wakeup handle: it
raises `SimBarrierError` directly, at the point of detection, via
`raiseSimBarrier`. The table below is the verified set, by grep of
`raiseSimBarrier`/`SimBarrierError` in `chronos/internal/asyncengine.nim`
against this page's own snapshot of the code -- not the RFC's
design-section sketch, which names a slightly larger surface that has
not all landed yet (see the note below the table).

| surface | mechanism |
|---|---|
| `register2`, `unregister2`, `addReader2`, `removeReader2`, `addWriter2`, `removeWriter2` (POSIX and Windows) | raises `SimBarrierError` directly, at the point of detection, through the otherwise-unchanged `Result` signature |
| `addSignal2`, `removeSignal2`, `addProcess2`, `removeProcess2` (POSIX and Windows) | same direct-raise mechanism |
| `unregisterAndCloseFd` (POSIX) | same direct-raise mechanism |
| `handle()` (minting a `DispatcherHandle`) | raises `SimBarrierError` directly rather than minting a handle for a sim dispatcher |
| `wake()` | raises `SimBarrierError` directly rather than writing to a zero-valued wakeup fd/port |
| `callSoon(DispatcherHandle, ...)` | raises `SimBarrierError` directly, the cross-thread entry `simProducer` replaces |
| `closeSocket`/`closeHandle` | not a barrier raise -- routes by dispatcher identity (a sim dispatcher's own `simFlushCloseInterest` path, never a real `closeFd` call), since every fd a sim dispatcher holds is sim-minted by construction |

`SimBarrierError` is `object of CatchableError`, deliberately not a
subtype of `AsyncError`, so an existing `except AsyncError` handler
cannot silently swallow a hermeticity violation -- the same
non-swallowing reasoning `SimLedgerError` follows. Its sibling
`SimEngineError` (`kind: SimFailureKind`) is the type the engine and
the sim poll loop raise directly for everything else they detect on
their own: an oracle error, an out-of-range oracle answer, a decision-
or virtual-time-budget exhaustion, a deadlock, or an oracle deferring
all deliverable work with no fallback (see
[`simulate`](#simulate-simulatewithbudget-simulatewithledger) above).
Classification is always by type -- `kind` for `SimEngineError`,
`exc.parent of ...` for `SimulationError` -- never by parsing a
message.

A `SimBarrierError`/`SimEngineError` a call site raises does not always
reach its caller unchanged. Three things can happen to it:

- **Propagation.** Most call sites let it through unchanged, widening
  their own `raises` list under `chronosSimulation` (see the sim-widened
  `async` signatures throughout `chronos/transports/stream.nim`,
  `chronos/transports/datagram.nim`, `chronos/threadsync.nim`, and
  `chronos/asyncproc.nim`). `runSimulation` (`chronos/simulation.nim`)
  is the ultimate boundary: it catches `SimEngineError` by type and
  converts it into `SimulationError`, and treats any other
  `CatchableError` -- including a propagated `SimBarrierError` -- as
  `SimFailureKind.BodyError`, indistinguishable from the body's own
  failure, which is exactly right: a barrier hit inside `body` is a
  bug in the body, not a distinct engine-detected condition.
- **Absorption.** `chronos/streams/asyncstream.nim`'s `tsource`-
  forwarding vtable procs absorb a `SimBarrierError`/`SimEngineError`
  the same way they already absorb `TransportError`: wrapped into
  `AsyncStreamReadError`/`AsyncStreamWriteError` rather than widening
  the vtable's declared `raises: [CancelledError, AsyncStreamError]`.
  The original still travels, as `.parent` on the wrapping error, so a
  caller that cares can still recover it by type; the identity never
  degrades below type, only the outer shape changes.
- **The Defect envelope.** A handful of touch sites cross a `raises:
  []`-typed boundary no per-build pragma can widen: a `CallbackFunc`
  (the transport seam's I/O-callback wrap and its `register2`/
  `addReader2`/etc. teardown calls) or `finish()`'s unbounded reach
  (`chronos/internal/asyncfutures.nim`'s `simLedgerNoteFutureFinish`).
  Each of these catches its own typed `SimBarrierError`/
  `SimEngineError`/`SimLedgerError` locally and re-raises it wrapped in
  a `Defect` via `raiseAsDefect` -- exempt from the raises effect
  system, the same mechanism `raiseOsDefect` already uses to cross an
  unwidenable boundary for an unrecoverable real-mode condition --
  instead of letting it propagate normally. `runSimulation` recovers
  the original by type (`exc.parent of SimLedgerError`/`SimEngineError`/
  `SimBarrierError`), never by parsing `exc.msg`. This is the one
  narrow, type-checked exception to typed-channel retirement, forced by
  those boundaries' reach rather than chosen for convenience; any other
  `Defect` reaching this boundary (a genuine unrecoverable condition,
  e.g. `raiseOsDefect`) is not this concern and re-raises unchanged.

**Named in the RFC's design section, not yet wired in code as of this
page:** `ThreadSignalPtr.fire`/`.wait` and `threadsync.waitSync` (RFC
0003 section 3.2's typed-raises row) show no `chronosSimulation`
awareness in `chronos/threadsync.nim` today. `asyncproc` spawning is
covered indirectly, through `addProcess2`, which is barriered; direct
`ThreadSignalPtr`/`waitSync` use under simulation is an open gap, not a
documented guarantee -- recorded here so a test relying on it does not
discover the gap by surprise.

## Performance

`chronosSimulation` undefined: **zero cost, verified by inspection.**
Every touchpoint this page's underlying laws (contextvar accounting,
timer accounting) and the waiter-conservation registration API add to
`chronos/internal/asyncengine.nim` sits inside an existing or newly
added `when chronosSimulation:` block; none of it compiles when the
define is off. The one unconditional addition is
`chronos/asyncsync.nim`'s new `AsyncEventQueue.waitersCount` accessor
(alongside the cherry-picked `waitersCount`/`gettersCount`/
`puttersCount` family) -- pure, additive, read-only procs that no
existing call site invokes, so they add a symbol to the binary and
nothing to any hot path. This matches invariant 1 and the bench-verdict
discipline slices S1 and S10 established (a fresh cross-commit bench run
was not repeated for this slice; the code-level argument -- no
unconditional new code on any real-mode call site -- is the same kind
of evidence a byte-identical generated-C diff would have given, and is
exhaustive here since every edit is mechanically `when`-gated or
additive).

`chronosSimulation` defined but a run either uses the plain
`simulate`/`sweepSeeds` (no ledger) or isn't simulating at all (a real
production dispatcher inside a sim-enabled test binary): each new
touchpoint pays one extra `nil` check (`if not simLedgerHookHere.isNil`)
beyond what slice S14 already paid for callback/future conservation --
the same cost class slice S1's inactive clock seam measured as noise
(one thread-local read plus one predicted branch). Per RFC section 3.4's
own policy, sim-enabled builds are test builds nobody benchmarks, so
this is not bench-gated either.

`simulateWithLedger` active (the real new cost, paid only by a test that
opts in): O(1) counter increments per touchpoint for contextvar and
timer accounting, matching callback conservation's existing cost; at
`simulate()` teardown, one additional per-item context check folded
into the callback-conservation drain that already walks every resident
callback (no new big-O cost); and O(k) waiter-primitive accessor calls,
where k is the number of primitives a test explicitly registered
(typically single digits). This is squarely a verification-tool cost,
exactly what RFC 0003 section 3.9 promises: "a verification tool, not a
change to `simulate()`'s default behavior."

## Surfaces that need no seam

`chronos/asyncsync.nim` (locks, events, queues, semaphores, the event
bus) is pure `Future` machinery with no OS coupling, so it runs
unmodified under simulation with zero instrumentation beyond the
read-only waiter-conservation accessors above. This is the same
statement RFC 0003 section 3.1 makes about the coverage claim: every
public surface is either driven by an oracle choice point, barriered,
or listed here as OS-free.

## Tests

Sim substrate tests live under `tests/testsim*.nim` (registered in both
the `test_simulation` nimble task and `nimble check_windows`, plus
`tests/testall.nim`): `testsimclock`, `testsimengine`, `testsimloop`,
`testsimoracle`, `testsimtrace`, `testsimulation`, `testsimstream`,
`testsimnet`, `testsimdatagram`, `testsimproducer`, and `testsimledger`
(the ghost-ledger laws, including this page's contextvar, timer, and
waiter-conservation additions). Every sim leaf test drives its probes
from a freshly spawned OS thread (`tests/testsimnet.nim`'s pattern),
isolating each scenario's own sim dispatcher from `testall`'s shared
real one. `nimble test_simulation` runs the full set under both
`--mm:refc` and `--mm:orc`, pinned to Nim 2.x (the sim substrate is
fork-only test infrastructure and does not carry the 1.6 design
constraints the contextvars series had to fight).
