#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## The D8 ghost-ledger laws (RFC 0003 3.9, slices S14/S15): callback
## conservation, future lifecycle, contextvar accounting, timer
## accounting, and waiter conservation, checked at step boundaries (one
## step is one outermost `fireWithContext` return, asyncengine.nim) plus
## a final check at `simulate()` teardown. Deliberately separate from
## the decision plumbing in `simengine.nim`: this module owns the laws
## and `SimLedgerError`, not the choice points a `SimOracle` answers.
##
## Leaf w.r.t. the dispatcher: never imports `asyncengine.nim` or
## `internal/asyncfutures.nim` back, the same one-way rule
## `simengine.nim` follows (RFC 0003 3.5) - `simengine.nim` imports this
## module to carry a `SimLedgerState` on `SimEngineState`, and
## `internal/asyncfutures.nim` imports it directly to report future-
## lifecycle transitions from `finish()`.
##
## Slice S15's primitive-discovery design decision (waiter
## conservation): three shapes were on the table - registration at
## construction (a hook inside `newAsyncLock`/`newAsyncEvent`/etc.,
## i.e. a seam), check-at-use (a hook inside `acquire`/`release`/`wait`/
## `set`/etc., also a seam), or test-registered (the caller of
## `simulateWith(seed, simOptions(ledger = true))` opts a primitive in
## explicitly, after constructing it normally). The amendment's own
## words - "the law
## reads state through the ... accessors ... and changes no behavior -
## asyncsync still needs no seam" - rule out the first two directly, so
## this module implements the third: `registerWaiterPrimitive` stores a
## `(desc, countProc)` pair with no dependency on `asyncsync.nim` at
## all (`countProc` is supplied by the caller, typically
## `chronos/simulation.nim`'s typed `simLedgerTrackWaiters` overloads).
## It is also the least invasive of the three under S14's opt-in
## discipline: zero define-off cost (nothing compiles when
## `chronosSimulation` is undefined), zero cost for every
## `simulate()`/`sweepSeeds` caller that never opted into ledger
## checking, and zero cost for a ledger-checked run that never calls
## `registerWaiterPrimitive`, matching the `ledger.isNil` early-out
## already established for the S14 laws.
##
## The waiter-conservation law's teardown check
## (`checkWaiterTeardown`) is where the law has real bug-catching teeth
## (RFC 0003 6, S15's RED phase): a registered primitive's `countProc`
## excludes cancelled waiters by construction (the accessors' own
## documented semantics), so a nonzero reading at `simulate()` teardown
## means a future is parked and neither woken nor cancelled - a
## `race()`/`one()`-style abandoned wait, the exact leak the 2026-08-15
## amendment names. A per-step reading of the same accessor mid-run
## cannot distinguish a legitimate in-flight wait (the overwhelmingly
## common case - a lock held with another task waiting on it) from a
## leak, since both read as "currently parked"; only the teardown
## reading, taken after the body's future has finished and nothing
## further will ever wake or cancel anything, gives the accessor a
## definite right answer. This module still exposes `waiterPrimitives`
## for a future per-step diagnostic reading if one proves useful, but
## the enforcement point - the one that raises `SimLedgerError` - is
## teardown-only, recorded here as the slice's judgment call.

{.push raises: [], gcsafe.}

import std/tables
import ../futures

type
  SimLedgerError* = object of CatchableError
    ## Raised by `chronos/simulation.nim`'s ledger-aware harness entry
    ## points for a violation of RFC 0003 3.9's conservation laws.
    ## Deliberately not a subtype of `AsyncError` - the same non-
    ## swallowing reasoning as `SimBarrierError` (3.2): an existing
    ## `except AsyncError` handler must not silently eat a ledger
    ## violation. A distinct type, not `SimulationError` with a new
    ## `SimFailureKind` member, so a test distinguishes a ledger
    ## violation from a barrier hit or oracle failure by type, never by
    ## string-matching the message (3.9's own requirement).
    seed*: uint64
    step*: int
    objectDesc*: string

  SimLedgerQueueKind* {.pure.} = enum
    ## The three dispatcher `CallbackQueue`s (asyncengine.nim's
    ## `DispatcherBase.callbacks`/`idlers`/`ticks`) the callback-
    ## conservation law is checked "per queue" against (RFC 0003 3.9).
    Callbacks
    Idlers
    Ticks

  SimLedgerQueueCounts = object
    ## `fired` means "left this queue for good": a real callback fire
    ## for `Callbacks`, or a transfer into `Callbacks` for `Idlers`/
    ## `Ticks` (which never fire directly - `processIdlers`/
    ## `processTicks` move their pop into `Callbacks`, itself a fresh
    ## `Callbacks` enqueue counted separately). `nilPops` only applies
    ## to `Callbacks`: `processCallbacksBody`'s
    ## `if not(isNil(callable.function))` guard, the nil-function-pop
    ## category S14 settles the reachability of (see
    ## `tests/testsimledger.nim`) - named here either way so a count
    ## can never silently leak through it (RFC 0003 3.9).
    enqueued: uint64
    fired: uint64
    nilPops: uint64

  SimLedgerFutureRecord = object
    state: FutureState
    desc: string

  SimLedgerContextCounts = object
    ## Slice S15's contextvar-accounting law: capture and restore balance
    ## across every scheduling point (RFC 0003 3.9). `captured` is
    ## incremented wherever a callback carrying a non-nil captured
    ## context enters `DispatcherBase.callbacks` (asyncengine.nim's
    ## `Callbacks`-kind `noteEnqueue` touchpoints, extended); `restored`
    ## is incremented once per real fire whose callback carried a
    ## context (`fireWithContext`'s `simLedgerFireOne` wrapper). A
    ## captured-but-not-yet-fired callback is legitimately still resident
    ## in `Callbacks` between checkpoints - `checkContextConservation`'s
    ## `residentWithContext` parameter is that term, the context-scoped
    ## analogue of `checkQueueConservation`'s `residentLen`. Checked only
    ## at `simulate()` teardown, not per-fire like callback/timer
    ## conservation: `DispatcherBase.callbacks` (`CallbackQueue`,
    ## `internal/callbackqueue.nim`) exposes no iteration or random
    ## access - by design, exactly five entry points - so there is no
    ## cheap way to read "how many queued callbacks carry a context" at
    ## an arbitrary mid-run checkpoint. Teardown's own unconditional
    ## drain (`simLedgerTeardownCheck`) already walks every resident
    ## entry via the queue's public `popFirst` for the callback-
    ## conservation check, so inspecting `.context` there is free; a
    ## true mid-run reading would need a sixth entry point on a queue
    ## type documented as deliberately narrow, which this slice judged
    ## not worth adding for a diagnostic cadence, not a detection gap -
    ## `captured`/`restored` are still counted at their real, independent
    ## touchpoints regardless of when the formula is evaluated.
    captured: uint64
    restored: uint64

  SimLedgerTimerCounts = object
    ## Slice S15's timer-accounting law: armed equals fired plus
    ## cancelled plus pending against the heap's contents (RFC 0003 3.9).
    ## `armed` counts `setTimer` pushes; `fired` counts a heap pop whose
    ## callback transfers into `Callbacks` (timer expiry); `cancelled`
    ## counts a heap entry that leaves without firing - either
    ## `removeTimer`'s immediate `HeapQueue.del`, or a `clearTimer`-ed
    ## (nil-function) entry discovered and discarded by the lazy sweep
    ## in `processTimers`/`processTimersGetTimeout`. `pending` (the
    ## live heap length at the checkpoint) is read directly, never
    ## tracked as a running counter, so a zombie entry between
    ## `clearTimer` and its eventual sweep is counted exactly once,
    ## as `pending`, never simultaneously as `cancelled`.
    armed: uint64
    fired: uint64
    cancelled: uint64

  SimLedgerWaiterPrimitive = object
    ## One asyncsync primitive opted into slice S15's waiter-conservation
    ## law (RFC 0003 3.9, the 2026-08-15 amendment) via
    ## `chronos/simulation.nim`'s `simLedgerTrackWaiters` family:
    ## `desc` names it in a violation ("AsyncLock.waiters" etc.),
    ## `countProc` is the primitive's own `waitersCount`/`gettersCount`/
    ## `puttersCount` read-only accessor (from
    ## `feat/asyncsync-waiters-introspection`, plus this slice's own
    ## `AsyncEventQueue` accessor) - `asyncsync.nim` gains no seam for
    ## this law, unlike the context/timer laws above: registration is
    ## test-side (the least invasive of the three discovery shapes the
    ## slice considered - see the module docstring), and the law reads
    ## state purely through the accessor, never through a hook inside
    ## `acquire`/`release`/`wait`/`set`/`get`/`put`.
    desc: string
    countProc: proc(): int {.gcsafe, raises: [].}

  SimLedgerState* = ref object
    ## One per sim run, carried on `SimEngineState` (`simengine.nim`)
    ## only when a caller opts into ledger checking (RFC 0003 3.9 is a
    ## verification tool, not a change to `simulate()`'s default
    ## behavior - see `chronos/simulation.nim`'s
    ## `simulateWith(seed, simOptions(ledger = true))`).
    queues: array[SimLedgerQueueKind, SimLedgerQueueCounts]
    stepDepth: int
    stepIndex: int
    futureRecords: Table[uint, SimLedgerFutureRecord]
    context: SimLedgerContextCounts
    timers: SimLedgerTimerCounts
    waiterPrimitives: seq[SimLedgerWaiterPrimitive]

const
  ledgerViolationPrefix* = "simulation invariant violation: "
    ## RFC 0003 3.9: "The message says 'simulation invariant violation:
    ## <law> ...', not 'ghost ledger'" - still true of `SimLedgerError.msg`,
    ## though nothing parses it anymore: `raiseLedgerViolation` below
    ## raises the typed `SimLedgerError` directly, classified by every
    ## catcher through Nim's own exception type, never through this
    ## prefix.

proc newSimLedgerState*(): SimLedgerState =
  SimLedgerState()

proc raiseLedgerViolation(ledger: SimLedgerState, law, detail,
                           objectDesc: string) {.noreturn,
                           raises: [SimLedgerError].} =
  ## Raised directly, at the point of detection, for a violation of any
  ## of RFC 0003 3.9's conservation laws - the same typed-at-the-source
  ## discipline `chronos/internal/simengine.nim`'s `raiseSimEngineError`
  ## follows. `chronos/internal/asyncfutures.nim`'s
  ## `simLedgerNoteFutureFinish` is the one caller (through
  ## `noteFutureTransition`) that cannot let this propagate as a normal
  ## exception - `finish()`'s reach is too broad (every future
  ## completion, including from inside a `CallbackFunc`, whose `raises:
  ## []` a Nim proc type cannot be conditionally widened) to carry a
  ## widened `raises` effect - so it catches this by type and re-raises
  ## it wrapped in a `Defect` (`raiseAsDefect`, exempt from the raises
  ## effect system) instead; `chronos/simulation.nim`'s `runSimulation`
  ## unwraps that one narrow, type-checked case back into this same
  ## `SimLedgerError`. Every other caller here - reached only from
  ## `asyncengine.nim`'s own poll loop or from `simLedgerTeardownCheck`,
  ## never from inside a `CallbackFunc` - lets it propagate directly.
  let exc = newException(SimLedgerError, ledgerViolationPrefix & law &
    ": " & detail & " (step=" & $ledger.stepIndex & ", object=" &
    objectDesc & ")")
  exc.step = ledger.stepIndex
  exc.objectDesc = objectDesc
  raise exc

# --- step boundaries (RFC 0003 3.9: one step is one outermost
# `fireWithContext` return) -------------------------------------------

proc beginStep*(ledger: SimLedgerState) {.inline.} =
  ## Called on every `fireWithContext` entry, nested or not. Reentrant
  ## `waitFor` (a nested `poll()` call synchronously inside a firing
  ## callback) is the only way `fireWithContext` itself nests; a
  ## synchronous cancellation cascade (`tryCancel` recursing through
  ## child futures, asyncfutures.nim) never re-enters
  ## `fireWithContext` - it fires cancel callbacks through a sibling
  ## mechanism (`fireCancelCallback`) that never opens a new step, so
  ## a cascade accounts to whichever step's `fireWithContext` call
  ## triggered it, with no extra bookkeeping needed here.
  inc ledger.stepDepth

proc endStep*(ledger: SimLedgerState) {.inline.} =
  ## Only the outermost `beginStep`/`endStep` pair (depth 1 -> 0)
  ## closes a step and advances the step index - nested fires from a
  ## reentrant `waitFor` account to the enclosing step (RFC 0003 3.9).
  dec ledger.stepDepth
  if ledger.stepDepth == 0:
    inc ledger.stepIndex

proc currentStep*(ledger: SimLedgerState): int {.inline.} =
  ledger.stepIndex

proc nilPopCount*(ledger: SimLedgerState, kind: SimLedgerQueueKind): uint64
    {.inline.} =
  ## Test-only introspection (RFC 0003 slice S14): the nil-function-pop
  ## category `processCallbacksBody`'s `if not(isNil(callable.function))`
  ## guards against - see `tests/testsimledger.nim` for the
  ## reachability settlement this exists to pin.
  ledger.queues[kind].nilPops

# --- callback conservation --------------------------------------------

proc noteEnqueue*(ledger: SimLedgerState, kind: SimLedgerQueueKind) {.inline.} =
  inc ledger.queues[kind].enqueued

proc noteFired*(ledger: SimLedgerState, kind: SimLedgerQueueKind) {.inline.} =
  inc ledger.queues[kind].fired

proc noteNilPop*(ledger: SimLedgerState, kind: SimLedgerQueueKind) {.inline.} =
  inc ledger.queues[kind].nilPops

proc checkQueueConservation*(ledger: SimLedgerState, kind: SimLedgerQueueKind,
                              residentLen: int) {.raises: [SimLedgerError].} =
  ## "Enqueued equals fired plus explicitly dropped at teardown plus
  ## nil-function pops, per queue" (RFC 0003 3.9): `residentLen` is
  ## whatever has not yet left the queue at the moment of this check -
  ## mid-run, that is "still queued, will be accounted at a later
  ## checkpoint"; at teardown (the caller's last call for this `kind`),
  ## it is exactly the "explicitly dropped at teardown" term the law
  ## names. One formula serves both: conservation must hold at every
  ## checkpoint, not only at the end.
  let q = ledger.queues[kind]
  let accounted = q.fired + q.nilPops + uint64(residentLen)
  if accounted != q.enqueued:
    raiseLedgerViolation(ledger, "callback conservation",
      $kind & " queue: enqueued=" & $q.enqueued & " but fired=" &
      $q.fired & " + nilPops=" & $q.nilPops & " + resident=" &
      $residentLen & " (=" & $accounted & ")",
      $kind & " queue")

# --- future lifecycle ---------------------------------------------------

proc noteFutureTransition*(ledger: SimLedgerState, id: uint, state: FutureState,
                            desc: string) {.raises: [SimLedgerError].} =
  ## Records `id`'s transition to a terminal `state` (RFC 0003 3.9's
  ## future-lifecycle law), raising if `id` was already observed
  ## terminal once before - the identity-based "no double completion"
  ## check. Called from the legitimate completion path
  ## (`internal/asyncfutures.nim`'s `finish()`, always after
  ## `checkFinished` has already passed) and, deliberately reachable
  ## from test code, a debug-only hook that forces a second transition
  ## to exercise this path for RED-phase coverage (RFC 0003 slice
  ## S14): a genuine second call to `finish()` on the same future can
  ## never reach here, since `checkFinished` raises an uncatchable-by-
  ## `simulate()` `FutureDefect` first. See `raiseLedgerViolation`'s
  ## docstring for how this proc's typed raise gets from here, inside
  ## `finish()`'s effect-unconstrained reach, back out as a typed
  ## `SimLedgerError` at `simulate()`.
  if state == FutureState.Pending:
    return
  let existing = ledger.futureRecords.getOrDefault(id)
  if existing.state != FutureState.Pending:
    raiseLedgerViolation(ledger, "future lifecycle",
      desc & ": observed " & $existing.state & ", now " & $state, desc)
  ledger.futureRecords[id] = SimLedgerFutureRecord(state: state, desc: desc)

# --- contextvar accounting (RFC 0003 slice S15) --------------------------

proc noteContextCaptured*(ledger: SimLedgerState) {.inline.} =
  ## A callback carrying a non-nil captured context entered
  ## `DispatcherBase.callbacks` (asyncengine.nim's `Callbacks`-kind
  ## `noteEnqueue` touchpoints, extended for this slice).
  inc ledger.context.captured

proc noteContextRestored*(ledger: SimLedgerState) {.inline.} =
  ## A real fire (`fireWithContext`) ran a callback that carried a
  ## captured context.
  inc ledger.context.restored

proc checkContextConservation*(ledger: SimLedgerState,
                                residentWithContext: int)
                               {.raises: [SimLedgerError].} =
  ## "Capture and restore balance across every scheduling point" (RFC
  ## 0003 3.9): the same conservation shape as `checkQueueConservation`,
  ## scoped to context-carrying callbacks - `residentWithContext` is the
  ## caller's fresh count of currently-queued callbacks whose `context`
  ## is non-nil (a captured-but-not-yet-fired callback is legitimate
  ## mid-run, and legitimately still resident at teardown if the body
  ## ended before it got a turn, the same "explicitly dropped at
  ## teardown" term callback conservation already grants).
  let c = ledger.context
  let accounted = c.restored + uint64(residentWithContext)
  if accounted != c.captured:
    raiseLedgerViolation(ledger, "contextvar conservation",
      "captured=" & $c.captured & " but restored=" & $c.restored &
      " + resident=" & $residentWithContext & " (=" & $accounted & ")",
      "context captures")

# --- timer accounting (RFC 0003 slice S15) --------------------------------

proc noteTimerArmed*(ledger: SimLedgerState) {.inline.} =
  inc ledger.timers.armed

proc noteTimerFired*(ledger: SimLedgerState) {.inline.} =
  ## A heap entry's deadline arrived and its callback transferred into
  ## `Callbacks` (`processTimers`/`processTimersGetTimeout`'s expiry
  ## loop) - distinct from the callback later actually firing out of
  ## `Callbacks`, which callback conservation already counts.
  inc ledger.timers.fired

proc noteTimerCancelled*(ledger: SimLedgerState) {.inline.} =
  ## A heap entry left without firing: either `removeTimer`'s immediate
  ## `HeapQueue.del`, or a `clearTimer`-ed (nil-function) entry
  ## discovered and discarded by the lazy sweep. Counted exactly once,
  ## at the moment the entry actually leaves the heap - never at
  ## `clearTimer` itself, which only marks a still-resident entry dead;
  ## counting there too would double-count against `pending` for the
  ## interval between the mark and the eventual sweep.
  inc ledger.timers.cancelled

proc checkTimerConservation*(ledger: SimLedgerState, pending: int)
                             {.raises: [SimLedgerError].} =
  ## "Armed equals fired plus cancelled plus pending against the heap's
  ## contents" (RFC 0003 3.9): `pending` is the caller's fresh
  ## `len(loop.timers)` read, never a running counter, so it always
  ## reflects exactly what is physically in the heap right now.
  let t = ledger.timers
  let accounted = t.fired + t.cancelled + uint64(pending)
  if accounted != t.armed:
    raiseLedgerViolation(ledger, "timer conservation",
      "armed=" & $t.armed & " but fired=" & $t.fired & " + cancelled=" &
      $t.cancelled & " + pending=" & $pending & " (=" & $accounted & ")",
      "timer heap")

# --- waiter conservation (RFC 0003 slice S15, 2026-08-15 amendment) -------

proc registerWaiterPrimitive*(ledger: SimLedgerState, desc: string,
    countProc: proc(): int {.gcsafe, raises: [].}) =
  ## Opts one asyncsync primitive into the waiter-conservation law (see
  ## this module's docstring for the test-registered discovery design
  ## decision). `chronos/simulation.nim`'s `simLedgerTrackWaiters`
  ## overloads are the intended callers, one per primitive kind, each
  ## supplying its own `waitersCount`/`gettersCount`/`puttersCount`
  ## accessor as `countProc`.
  ledger.waiterPrimitives.add SimLedgerWaiterPrimitive(
    desc: desc, countProc: countProc)

proc checkWaiterTeardown*(ledger: SimLedgerState) {.raises: [SimLedgerError].} =
  ## "Every waiter list empty at `simulate()` teardown" (RFC 0003 3.9's
  ## 2026-08-15 amendment): a nonzero reading from a registered
  ## primitive's accessor here means a future is parked and neither
  ## woken nor cancelled - a `race()`/`one()`-style abandoned wait. See
  ## this module's docstring for why the law's enforcement point is
  ## teardown-only, not every step boundary.
  for w in ledger.waiterPrimitives:
    let live = w.countProc()
    if live > 0:
      raiseLedgerViolation(ledger, "waiter conservation",
        w.desc & ": " & $live & " waiter(s) still parked at teardown " &
        "(never woken or cancelled)", w.desc)
