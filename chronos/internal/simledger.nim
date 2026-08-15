#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## The D8 ghost-ledger laws (RFC 0003 3.9, slice S14): callback
## conservation and future lifecycle, checked at step boundaries (one
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

  SimLedgerViolation* = object
    ## Populated immediately before the internal Defect carrying a
    ## ledger violation is raised. `asyncengine.nim` compiles under a
    ## file-wide `{.push raises: [].}` (RFC 0003 3.2's error-channel
    ## discussion applies here too): a law check running deep inside
    ## `poll()`'s call tree cannot `raise SimLedgerError` (a
    ## `CatchableError`) directly without widening that pragma, so the
    ## check raises a plain `Defect` (`raiseAssert`, exempt from the
    ## raises effect system, the same mechanism `simDecideBatch`/
    ## `simDecideTimeAdvance` already use for protocol violations) and
    ## stashes the structured fields here for `chronos/simulation.nim`'s
    ## harness - outside that raises-pushed tree - to read back and
    ## construct the real `SimLedgerError`.
    active*: bool
    step*: int
    objectDesc*: string

  SimLedgerState* = ref object
    ## One per sim run, carried on `SimEngineState` (`simengine.nim`)
    ## only when a caller opts into ledger checking (RFC 0003 3.9 is a
    ## verification tool, not a change to `simulate()`'s default
    ## behavior - see `chronos/simulation.nim`'s `simulateWithLedger`).
    queues: array[SimLedgerQueueKind, SimLedgerQueueCounts]
    stepDepth: int
    stepIndex: int
    futureRecords: Table[uint, SimLedgerFutureRecord]
    lastViolation*: SimLedgerViolation

const
  ledgerViolationPrefix* = "simulation invariant violation: "
    ## RFC 0003 3.9: "The message says 'simulation invariant violation:
    ## <law> ...', not 'ghost ledger'". `chronos/simulation.nim`
    ## recognizes this prefix to distinguish a ledger `Defect` from
    ## every other internal sim-loop/oracle `Defect` message.

proc newSimLedgerState*(): SimLedgerState =
  SimLedgerState()

proc raiseLedgerViolation(ledger: SimLedgerState, law, detail,
                           objectDesc: string) {.noreturn.} =
  ledger.lastViolation = SimLedgerViolation(
    active: true, step: ledger.stepIndex, objectDesc: objectDesc)
  raiseAssert ledgerViolationPrefix & law & ": " & detail &
    " (step=" & $ledger.stepIndex & ", object=" & objectDesc & ")"

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
                              residentLen: int) =
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
                            desc: string) =
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
  ## `simulate()` `FutureDefect` first.
  if state == FutureState.Pending:
    return
  let existing = ledger.futureRecords.getOrDefault(id)
  if existing.state != FutureState.Pending:
    raiseLedgerViolation(ledger, "future lifecycle",
      desc & ": observed " & $existing.state & ", now " & $state, desc)
  ledger.futureRecords[id] = SimLedgerFutureRecord(state: state, desc: desc)
