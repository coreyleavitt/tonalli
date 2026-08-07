## Layer 3: bisimulation vs a std/deques reference.
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh bisim`,
## once per MM (`MM=refc ./run.sh bisim`, `MM=orc ./run.sh bisim`).
##
## Unlike layers 1-2 (which walk hand-mirrored copies), this file imports
## the REAL, shipped `chronos/internal/callbackqueue.nim` directly, using
## only its five public entry points (`initCallbackQueue`, `addLast`,
## `addFirst`, `popFirst`, `len`) -- no private-field access needed.
##
## **Algorithm**: proptest's `bisimulationCheck` -- deterministic lock-step
## BFS over `(realState, refState)` product pairs, comparing (a)
## observations and (b) enabled-rule-name sets at every reached pair.
##
## **The `cap` shadow field.** Neither side exposes a capacity accessor
## (`std/deques.Deque` has no matching notion), but `addFirst`'s
## enabled-set must still agree between both sides (the real queue's
## `addFirst` doAsserts if full, and unlike `addLast` never grows). Both
## harness states carry an identical, independently-computed shadow `cap`
## field, updated by the same `growTargetCapShadow` arithmetic as the real
## module's private `growTargetCap`, triggered by the same precondition
## (`len == cap` before an `addLast`) and driven by the same shared rule
## sequence on both sides -- so the two shadow `cap`s stay in lockstep by
## construction, letting `addFirst`'s enabled-ness be computed identically
## on both sides without reading any real private field.
##
## **Observation**: the real interface has no peek/iteration, so FIFO
## order is proved by draining a VALUE COPY of the state at each reached
## pair (`CallbackQueue[T]`/`Deque[T]` are plain value objects with
## default copy semantics, so draining the copy never disturbs the state
## carried forward by the BFS). This checks FIFO order and enabled-op
## sets -- not internal slot state, which is layer 2's job.
##
## **Defect safety**: any of the three ops firing a real `doAssert` is
## converted from an uncatchable `Defect` to a `CatchableError` by
## `guardAsserts`, so `bisimulationCheck`'s own `except CatchableError`
## reports it as a distinguishing plan instead of aborting the whole run.
## This also makes layer 3 usable as a mutation-testing tool (layer 5): a
## mutant that trips an assert unexpectedly is caught cleanly instead of
## crashing the harness.

import std/[deques, hashes, strutils]
import proptest
import ../chronos/internal/callbackqueue

const
  initialCap = 2
    ## Deliberately small so growth -- and physical wraparound of the
    ## monotonic head/tail into a smaller backing -- is reached well
    ## inside the swept depth, not left to chance.
  bisimDepth = 12
  bisimMaxStates = 20_000
  tagLo = 0
  tagHi = 1_000_000

proc mmName(): string =
  when defined(gcOrc): "orc"
  elif defined(gcArc): "arc"
  elif defined(gcRefc): "refc"
  else: "unknown"

type
  RealState = object
    q: CallbackQueue[int]
    cap: int

  RefState = object
    dq: Deque[int]
    cap: int

template guardAsserts(where: string, body: untyped): untyped =
  ## `doAssert` raises a `Defect`, which `bisimulationCheck`'s own `except
  ## CatchableError` does NOT catch -- converting here is what turns an
  ## unexpected assert into a reported distinguishing plan instead of a
  ## hard process abort.
  try:
    body
  except Defect as chronosVerifyDefect:
    raise newException(ValueError,
      where & ": assertion fired -- " & chronosVerifyDefect.msg)

proc growTargetCapShadow(cap: int): int =
  ## Mirrors the real module's private `growTargetCap` exactly (same
  ## doubling rule, same zero-floor) -- verified byte-identical by
  ## `drift_check.nim`. Duplicated here only because the real proc is
  ## private; this is bookkeeping for the harness's `addFirst`-enabled
  ## computation, not a second implementation.
  if cap == 0: 8 else: cap * 2

proc mkRealInitial(): RealState =
  RealState(q: initCallbackQueue[int](initialCap), cap: initialCap)

proc mkRefInitial(): RefState =
  RefState(dq: initDeque[int](initialCap), cap: initialCap)

# --- rules: real side -------------------------------------------------------

proc doAddLastReal(s: var RealState, tag: int) =
  guardAsserts("real.addLast"):
    if s.q.len == s.cap: s.cap = growTargetCapShadow(s.cap)
    s.q.addLast(tag)

proc doAddFirstReal(s: var RealState, tag: int) =
  guardAsserts("real.addFirst"):
    # The real module's operation is named `prependNoGrow`. The
    # rule/guard LABEL stays "addFirst" (bisim's own vocabulary, shared
    # with the `std/deques` reference side below, which genuinely has
    # `addFirst`).
    s.q.prependNoGrow(tag)

proc addFirstEnabledReal(s: RealState): bool = s.q.len < s.cap

proc doPopFirstReal(s: var RealState, _: int) =
  guardAsserts("real.popFirst"):
    discard s.q.popFirst()

proc popFirstEnabledReal(s: RealState): bool = s.q.len > 0

proc observeReal(s: RealState): string =
  var qcopy = s.q # independent deep copy -- draining it never touches `s`
  var vals: seq[string]
  while qcopy.len > 0:
    vals.add $qcopy.popFirst()
  "len=" & $vals.len & "|" & vals.join(",")

# --- rules: reference side (std/deques) -------------------------------------

proc doAddLastRef(s: var RefState, tag: int) =
  if s.dq.len == s.cap: s.cap = growTargetCapShadow(s.cap)
  s.dq.addLast(tag)

proc doAddFirstRef(s: var RefState, tag: int) =
  s.dq.addFirst(tag)

proc addFirstEnabledRef(s: RefState): bool = s.dq.len < s.cap

proc doPopFirstRef(s: var RefState, _: int) =
  discard s.dq.popFirst()

proc popFirstEnabledRef(s: RefState): bool = s.dq.len > 0

proc observeRef(s: RefState): string =
  var dqcopy = s.dq
  var vals: seq[string]
  while dqcopy.len > 0:
    vals.add $dqcopy.popFirst()
  "len=" & $vals.len & "|" & vals.join(",")

# --- state hashes (dedup, keeps the swept state count low) -----------------

proc hashReal(s: RealState): Hash = !$(hash(s.q.len) !& hash(s.cap))
proc hashRef(s: RefState): Hash = !$(hash(s.dq.len) !& hash(s.cap))

# --- runner ------------------------------------------------------------------

proc mkSmReal(): StateMachine[RealState] =
  StateMachine[RealState](
    initial: just(mkRealInitial()),
    rules: @[
      rule[RealState, int]("addLast", integers(tagLo, tagHi), doAddLastReal),
      rule[RealState, int]("addFirst", integers(tagLo, tagHi), doAddFirstReal,
                           precondition = addFirstEnabledReal),
      rule[RealState, int]("popFirst", just(0), doPopFirstReal,
                           precondition = popFirstEnabledReal),
    ])

proc mkSmRef(): StateMachine[RefState] =
  StateMachine[RefState](
    initial: just(mkRefInitial()),
    rules: @[
      rule[RefState, int]("addLast", integers(tagLo, tagHi), doAddLastRef),
      rule[RefState, int]("addFirst", integers(tagLo, tagHi), doAddFirstRef,
                          precondition = addFirstEnabledRef),
      rule[RefState, int]("popFirst", just(0), doPopFirstRef,
                          precondition = popFirstEnabledRef),
    ])

echo "=== Layer 3: bisimulation vs std/deques reference ==="
echo "(maxDepth=" & $bisimDepth & ", maxStates=" & $bisimMaxStates &
     ", initialCap=" & $initialCap & ", mm=" & mmName() & ")"

let report = bisimulationCheck[RealState, RefState](
  mkSmReal(), mkRealInitial(), observeReal,
  mkSmRef(), mkRefInitial(), observeRef,
  settings = BmcSettings(maxDepth: bisimDepth, maxStates: bisimMaxStates),
  stateHash1 = hashReal, stateHash2 = hashRef)

case report.outcome
of bisimEquivalent:
  echo "EQUIVALENT (depth " & $bisimDepth & ", " & $report.statesExplored &
       " pairs explored) -- real CallbackQueue[int] and std/deques agree on " &
       "FIFO order, len, and enabled-op sets over every reachable plan"
of bisimDistinguishable:
  let plan = report.distinguishingPlan.get
  var steps: seq[string]
  for step in plan: steps.add step.ruleName
  echo "DISTINGUISHABLE at depth " & $plan.len & " -- plan: [" & steps.join(", ") & "]"
  echo "  real obs: " & report.initialObs1
  echo "  ref  obs: " & report.initialObs2
  doAssert false, "Layer 3 bisim: real CallbackQueue diverges from the std/deques reference " &
    "-- plan: [" & steps.join(", ") & "]"
of bisimExhaustedBudget:
  echo "BUDGET EXHAUSTED (" & $report.statesExplored & " states) -- inconclusive, raise maxStates"
  doAssert false, "Layer 3 bisim: exhausted budget before a verdict"

echo "=== Layer 3: EQUIVALENT ==="
