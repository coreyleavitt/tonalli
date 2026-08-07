## Layer 2: bmcCheck ghost-ownership model.
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh bmc`.
##
## Exhaustive breadth-first plan sweep (`bmcCheck`) over the real
## `CallbackQueue[GhostItem]` from `callbackqueue_model.nim` -- real
## `addLast`/`addFirst`/`popFirst`/`popFirstRejected` code runs on every
## step; growth's whole-region `copyMem`+`zeroMem` fires exactly as it will
## in the shipped queue. What is "ghost" is the ownership ledger layered
## around it: `GhostItem` carries no ref/destructor, so nothing here depends
## on the real allocator or either MM's actual barrier behavior (that is
## layer 4's job) -- the ledger is explicit bookkeeping that mirrors what a
## real write-barrier/move/raw-memory-op WOULD do to a refcount:
##
##   * A tracked transfer (`addLast`/`addFirst`'s slot commit; `popFirst`'s
##     `chronosMoveSink` vacate) moves the SAME ledger entry to a new
##     location -- the count never changes, only where it is attributed.
##   * `popFirstRejected`'s `copyMem` creates a usable alias WITHOUT
##     incrementing the ledger (raw memory, no barrier), and its `zeroMem`
##     strips the slot's tracked claim WITHOUT decrementing it (also raw,
##     also no barrier).
##
## **Refcount-conservation invariant**: for every id ever captured,
## `trueRefCount[id]` must always equal 1 if a tracked holder currently
## claims it, 0 otherwise. A tracked transfer preserves this by construction
## (same entry, relocated). The rejected shape breaks it: after
## `popFirstRejected`, `trueRefCount[id] == 1` but no tracked holder claims
## it -- an unreclaimable leak, not a double-free (see module doc in
## `callbackqueue_model.nim`).
##
## Six bmcCheck runs, two ownership shapes x three invariants:
##   1. FUSED    x refcountConserved  -> must VERIFY (the adopted shape is sound)
##   2. FUSED    x vacatedSlotZeroed  -> must VERIFY
##   3. FUSED    x no-assert-fires    -> must VERIFY
##   4. REJECTED x refcountConserved  -> must FALSIFY (the model has teeth)
##   5. REJECTED x vacatedSlotZeroed  -> must VERIFY (the rejected shape's
##      bug is in the LEDGER, not the raw slot content -- `zeroMem` really
##      does clear the slot)
##   6. REJECTED x no-assert-fires    -> must VERIFY (the bug is a silent
##      leak, not a crash -- no primitive-level doAssert ever catches it,
##      which is exactly why the ghost model has to exist)

import std/[tables, hashes, sets, options, strutils]
import proptest
import ./callbackqueue_model

const
  maxPlanDepth = 12
    ## Small, deliberate bound. Every rule is O(1) table/seq work; dedup
    ## below keeps the explored-state count in the low thousands even at
    ## this depth.
  maxPlanStates = 20_000
  initialQueueCap = 2
    ## Deliberately small so growth (and physical wraparound of the
    ## monotonic head/tail into a smaller backing) is reached well within
    ## `maxPlanDepth`, not left to chance.

type
  TrackedLoc = enum
    tlSlot        ## the queue slot itself currently claims the id
    tlCallerLocal ## a properly tracked (moved-into) caller-frame local claims it

  DequeueShape = enum
    dsFused          ## the adopted shape: chronosMoveSink-fused vacate
    dsRejectedCopyMem ## the rejected shape: copyMem + zeroMem vacate

  Ledger = object
    trueRefCount: Table[int, int]
      ## The refcount a real GC would maintain for each captured id.
    trackedHolder: Table[int, TrackedLoc]
      ## Present iff some GC-visible location currently claims the id.
    untrackedAlias: HashSet[int]
      ## ids with a live, GC-invisible alias outstanding (a copyMem'd local)
      ## -- tracked here purely for bookkeeping/diagnostics, never consulted
      ## by the refcount-conservation invariant itself.

  GhostState = object
    queue: CallbackQueue[GhostItem]
    ledger: Ledger
    nextId: int
    callerLocalFifo: seq[int]
      ## ids currently held by whatever `dequeue` last produced (tracked or
      ## not), awaiting `dispose` -- FIFO order mirrors "the oldest
      ## outstanding local goes out of scope first", an arbitrary but
      ## deterministic and sufficient choice (BMC sweeps ALL interleavings
      ## of *which* rule fires when regardless of this internal ordering).
    shape: DequeueShape

# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

template guardAsserts(where: string, body: untyped): untyped =
  ## `doAssert` raises a `Defect`, which `bmcCheck`'s own `except
  ## CatchableError` does NOT catch -- `Defect` and `CatchableError` are
  ## siblings under `Exception`, not parent/child, so an uncaught
  ## primitive-level assert would crash the whole BMC sweep instead of
  ## being reported as a falsification. Converting it here is what makes
  ## "no assert fires" a genuine, BMC-falsifiable claim.
  try:
    body
  except Defect as chronosVerifyDefect:
    raise newException(ValueError,
      where & ": assertion fired -- " & chronosVerifyDefect.msg)

proc captureAndSlot(s: var GhostState, id: int) =
  s.ledger.trueRefCount[id] = 1
  s.ledger.trackedHolder[id] = tlSlot

proc doEnqueue(s: var GhostState, _: int) =
  let id = s.nextId
  inc s.nextId
  captureAndSlot(s, id)
  guardAsserts("enqueue"):
    s.queue.addLast(GhostItem(id: id))

proc doAddFirst(s: var GhostState, _: int) =
  let id = s.nextId
  inc s.nextId
  captureAndSlot(s, id)
  guardAsserts("addFirst"):
    s.queue.addFirst(GhostItem(id: id))

proc addFirstEnabled(s: GhostState): bool =
  s.queue.len < s.queue.cap

proc doDequeue(s: var GhostState, _: int) =
  guardAsserts("dequeue"):
    case s.shape
    of dsFused:
      let item = s.queue.popFirst()
      # Atomic transfer: the SAME ledger entry relocates from tlSlot to
      # tlCallerLocal. The count is untouched by construction -- there is
      # no code path here that could duplicate or drop it.
      s.ledger.trackedHolder[item.id] = tlCallerLocal
      s.callerLocalFifo.add item.id
    of dsRejectedCopyMem:
      let item = s.queue.popFirstRejected()
      # copyMem: a usable alias now exists, untracked (no ledger
      # increment -- raw memory, no barrier).
      s.ledger.untrackedAlias.incl item.id
      # zeroMem: the slot's tracked claim is stripped WITHOUT a
      # decrement -- the sole counted reference is gone from the
      # ledger's perspective while trueRefCount still says 1. This
      # single line IS the modeled bug.
      s.ledger.trackedHolder.del(item.id)
      s.callerLocalFifo.add item.id

proc dequeueEnabled(s: GhostState): bool =
  s.queue.len > 0

proc doDispose(s: var GhostState, _: int) =
  let id = s.callerLocalFifo[0]
  s.callerLocalFifo.delete(0)
  if id in s.ledger.trackedHolder and
      s.ledger.trackedHolder[id] == tlCallerLocal:
    # A genuinely tracked local going out of scope: the one real
    # decrement in a well-behaved lifecycle.
    s.ledger.trueRefCount[id] = s.ledger.trueRefCount[id] - 1
    s.ledger.trackedHolder.del(id)
  # else: this id's only claim was an untracked alias (the rejected
  # shape). Its scope exit triggers NO decrement -- there is no hook for
  # it to trigger. `trueRefCount` is deliberately left untouched.
  s.ledger.untrackedAlias.excl id

proc disposeEnabled(s: GhostState): bool =
  s.callerLocalFifo.len > 0

proc mkRules(): seq[Rule[GhostState]] =
  @[
    rule[GhostState, int]("enqueue", just(0), doEnqueue),
    rule[GhostState, int]("addFirst", just(0), doAddFirst,
                          precondition = addFirstEnabled),
    rule[GhostState, int]("dequeue", just(0), doDequeue,
                          precondition = dequeueEnabled),
    rule[GhostState, int]("dispose", just(0), doDispose,
                          precondition = disposeEnabled),
  ]

# ---------------------------------------------------------------------------
# Invariants
# ---------------------------------------------------------------------------

proc refcountConserved(s: GhostState): bool =
  ## Every captured id: trueRefCount == 1 iff a tracked holder claims it,
  ## else 0. This is the refcount-conservation invariant.
  for id in 0 ..< s.nextId:
    let trc = s.ledger.trueRefCount.getOrDefault(id, 0)
    let trackedCount = (if id in s.ledger.trackedHolder: 1 else: 0)
    if trc != trackedCount:
      return false
  true

proc vacatedSlotsZeroedWhenEmpty(s: GhostState): bool =
  ## No non-nil ghost slots survive a full drain. Checked physically against the raw
  ## backing, not the ledger -- this must hold for BOTH shapes (the
  ## rejected shape's bug is in the ledger, not the raw slot content).
  if s.queue.len == 0:
    for i in 0 ..< s.queue.cap:
      if s.queue.rawSlot(i).id != 0:
        return false
  true

proc alwaysTrue(s: GhostState): bool = true
  ## Trivial invariant: exists only so `bmcCheck`'s exception-as-
  ## falsification path (see `guardAsserts` above) is the sole source of
  ## `bmcFalsified` here -- proving no primitive-level doAssert is
  ## reachable across the whole swept plan space, independent of the
  ## refcount/slot-content invariants above.

# ---------------------------------------------------------------------------
# Dedup hash -- structural, id-relabeling-invariant (sound for these
# invariants: none of them depend on WHICH id occupies a role, only on the
# aggregate shape of the ledger and the queue's physical state).
# ---------------------------------------------------------------------------

proc stateHash(s: GhostState): Hash =
  var slotHeld, callerHeld, untracked, mismatched = 0
  for id in 0 ..< s.nextId:
    let trc = s.ledger.trueRefCount.getOrDefault(id, 0)
    let holder = s.ledger.trackedHolder.getOrDefault(id, tlSlot)
    let hasHolder = id in s.ledger.trackedHolder
    if hasHolder and holder == tlSlot: inc slotHeld
    elif hasHolder and holder == tlCallerLocal: inc callerHeld
    if id in s.ledger.untrackedAlias: inc untracked
    if trc != (if hasHolder: 1 else: 0): inc mismatched
  var h: Hash = 0
  h = h !& hash(s.queue.len) !& hash(s.queue.cap) !& hash(s.callerLocalFifo.len)
  h = h !& hash(slotHeld) !& hash(callerHeld) !& hash(untracked) !& hash(mismatched)
  result = !$h

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

proc mkInitial(shape: DequeueShape): GhostState =
  GhostState(
    queue: initCallbackQueue[GhostItem](initialQueueCap),
    ledger: Ledger(),
    nextId: 0,
    callerLocalFifo: @[],
    shape: shape)

proc mkSM(shape: DequeueShape): StateMachine[GhostState] =
  StateMachine[GhostState](
    initial: just(mkInitial(shape)),
    rules: mkRules())

proc runBmc(label: string, shape: DequeueShape,
            invariant: proc(s: GhostState): bool,
            expectVerified: bool) =
  let sm = mkSM(shape)
  let r = bmcCheck(sm, initial = mkInitial(shape), invariant = invariant,
                    settings = BmcSettings(maxDepth: maxPlanDepth,
                                            maxStates: maxPlanStates),
                    stateHash = stateHash)
  stdout.write "  " & label & " ... "
  case r.outcome
  of bmcVerified:
    echo "VERIFIED (depth " & $r.depthReached & ", " & $r.statesExplored &
         " states explored)"
    doAssert expectVerified, label & ": expected VERIFIED, matches"
  of bmcFalsified:
    let plan = r.counterexample.get
    var steps: seq[string]
    for step in plan: steps.add step.ruleName
    echo "FALSIFIED at depth " & $plan.len & " -- plan: [" &
         steps.join(", ") & "]"
    doAssert not expectVerified,
      label & ": expected VERIFIED but got FALSIFIED -- plan: [" &
      steps.join(", ") & "]"
  of bmcExhaustedBudget:
    echo "BUDGET EXHAUSTED (" & $r.statesExplored & " states, depth " &
         $maxPlanDepth & ") -- inconclusive, raise maxStates"
    doAssert false, label & ": exhausted budget before a verdict"

echo "=== Layer 2: bmcCheck ghost-ownership model ==="
echo "(maxDepth=" & $maxPlanDepth & ", maxStates=" & $maxPlanStates &
     ", initialCap=" & $initialQueueCap & ")"

runBmc("FUSED    x refcountConserved", dsFused, refcountConserved,
       expectVerified = true)
runBmc("FUSED    x vacatedSlotZeroed", dsFused, vacatedSlotsZeroedWhenEmpty,
       expectVerified = true)
runBmc("FUSED    x no-assert-fires  ", dsFused, alwaysTrue,
       expectVerified = true)
runBmc("REJECTED x refcountConserved", dsRejectedCopyMem, refcountConserved,
       expectVerified = false)
runBmc("REJECTED x vacatedSlotZeroed", dsRejectedCopyMem,
       vacatedSlotsZeroedWhenEmpty, expectVerified = true)
runBmc("REJECTED x no-assert-fires  ", dsRejectedCopyMem, alwaysTrue,
       expectVerified = true)

echo "=== Layer 2: all six runs matched their expected verdict ==="
