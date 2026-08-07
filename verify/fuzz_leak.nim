## RFC 0001 D9-V / S11 — Layer 4: coverage-guided fuzz + GC stress + leak
## accounting, and a dedicated Defect-unwind check.
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh fuzz`, once
## per MM (`MM=refc ./run.sh fuzz`, `MM=orc ./run.sh fuzz`).
##
## Imports the REAL `chronos/internal/callbackqueue.nim` directly (S11 --
## see `bisim_check.nim`'s module doc for why layers 3-5 do this and
## layers 1-2 do not). This is the only layer that exercises the real
## allocator under a real memory manager -- the standing leak check on the
## fused-move dequeue's conservation argument (RFC 0001 D9's rejected-shapes
## analysis: the `copyMem`-dequeue shape was rejected BECAUSE it leaks; this
## file is what proves the ADOPTED shape does not, against the real
## `--mm:refc`/`--mm:orc` allocators rather than S9's ghost ledger).
##
## **Coverage-guided fuzz, honestly scoped.** `proptest/fuzz`'s `fuzzWith`
## is coverage-guided when the SUT carries `{.cover.}` instrumentation
## (`proptest/coverage.nim`). `chronos/internal/callbackqueue.nim` is
## upstream-bound and MUST NOT carry any fork-only pragma or import (RFC
## 0001's segregation mandate) -- so it is never instrumented, and per
## `fuzz.nim`'s own module doc ("An uninstrumented SUT degrades gracefully
## to 'random fuzzing'"), this run is honestly a random IR-mutation fuzz
## over IR-mode's structural mutators (perturb-integer, kind-boundary,
## span-splice/delete/duplicate -- `mutateIRPerturbInteger` etc. in
## `proptest/fuzz.nim`), not edge-coverage-directed. Still real value: the
## IR mutators explore op-sequence SHAPE (lengths, op-kind boundaries,
## spliced sub-sequences from other corpus entries) more effectively than
## pure independent-draw random generation, and every `vInteresting`
## finding (a crash OR a leak-accounting assertion, both wired into `prop`
## below) is a genuine harness failure either way.
##
## **Leak accounting.** Item = `ref object` (heap-allocated, GC-traced --
## the real allocator's own bookkeeping, not a ghost ledger). Each `prop`
## call: replay a generated op sequence against a FRESH real
## `CallbackQueue[LeakItem]`, force a full drain regardless of how the
## sequence ended, `GC_fullCollect()`, then assert `getOccupiedMem()` is
## within `toleranceBytes` of a baseline captured once at program start
## (after a warm-up round -- empirically, both MMs show a one-time bump on
## the first few GC-traced allocations as internal allocator structures
## grow, then plateau; warming up before sampling the baseline avoids
## mistaking that one-time bump for drift). A genuine per-op leak
## accumulates roughly linearly with iterations and trips this assertion
## within a handful of iterations, well before the fuzz budget is spent
## (empirically verified against a real leak: see `verify/README.md`'s
## ledger for the calibration numbers this tolerance was chosen against).
##
## **Defect-unwind sequences.** `popFirst()` on empty and `addFirst()` on a
## full queue both `doAssert`, raising a `Defect`. Under this fork's
## standing `panics:off` assumption (RFC 0001 round 2), a `Defect` remains
## a catchable exception (not a `--panics:on` fatal abort), so both are
## exercised directly here in `runDefectUnwindChecks` -- expressible
## without killing the process, per the slice's own escalation clause --
## confirming both (a) the assert fires and is catchable, and (b) the
## queue remains fully usable for subsequent ops afterward (mirrors
## `tests/testcallbackqueue.nim`'s "post-Defect-unwind queue integrity"
## pin, but driven at the queue's own API boundary rather than through a
## caller's try/except around a drain loop).

import std/[times, strutils, tables, algorithm]
import proptest
import ../chronos/internal/callbackqueue

type
  LeakItem = ref object
    id: int

  QOpKind = enum
    qoAddLast, qoAddFirst, qoPopFirst

const
  maxOpsPerSeq = 300
  fuzzIterations = 50_000
    ## Budgeted for "minutes, not hours" (RFC 0001 S11 scope note).
    ## Empirically, 4000 iterations at this op-sequence length ran in
    ## ~1-2 seconds per MM (see verify/README.md's ledger) -- comfortable
    ## headroom to scale up for a more thorough leak/crash sweep while
    ## staying at low-single-digit-seconds wall-clock, nowhere near the
    ## 90s safety-net budget below. Each iteration replays up to
    ## `maxOpsPerSeq` queue ops plus a full drain and a `GC_fullCollect()`;
    ## 50,000 iterations x up to 300 ops is up to 15M queue operations per
    ## MM run.
  fuzzTimeBudgetSeconds = 90
    ## Safety net, not the primary stop condition (iterations is).
  toleranceBytes = 1_000_000
    ## 1 MB. Generous relative to one sequence's worst-case live set
    ## (300 items x a `ref object` with one `int` field, on the order of a
    ## few KB even before GC reclaims it) so runtime/allocator bookkeeping
    ## noise across thousands of iterations never false-positives, while
    ## still tight enough that a genuine per-op leak (each leaked
    ## `LeakItem` several dozen bytes) trips this well within the
    ## iteration budget -- see the module doc's calibration note.

proc mmName(): string =
  when defined(gcOrc): "orc"
  elif defined(gcArc): "arc"
  elif defined(gcRefc): "refc"
  else: "unknown"

template guardAsserts(where: string, body: untyped): untyped =
  ## Same discipline as `bisim_check.nim`/S9's `bmc_ghost.nim`: convert an
  ## unexpected `doAssert`-raised `Defect` into a `CatchableError` so
  ## `fuzzWith`'s target still reports it as a finding (`vInteresting`)
  ## rather than merely relying on `inProcessTarget`'s own `except Defect`
  ## catch (which also works -- this wrapper adds the `where` context to
  ## the message for a more useful crash report).
  try:
    body
  except Defect as chronosVerifyDefect:
    raise newException(ValueError,
      where & ": assertion fired -- " & chronosVerifyDefect.msg)

proc growTargetCapShadow(cap: int): int =
  ## See `bisim_check.nim`'s module doc: mirrors the real private
  ## `growTargetCap` exactly, verified by `drift_check.nim`.
  if cap == 0: 8 else: cap * 2

var baselineOcc: int
  ## Set once by `warmUpAndCaptureBaseline`, before the fuzz loop starts.

## --- Phase 3 (B-wave) coverage accounting -------------------------------
##
## Per-run observations, from public observations only -- no pragmas on
## `chronos/internal/callbackqueue.nim`, nothing reads its private fields.
## Two of the three signals reuse machinery already present in this file:
##
## - **final capacity**: the existing `cap` shadow local (already tracked
##   per-`prop()`-call via `growTargetCapShadow`, the same shadow arithmetic
##   `bisim_check.nim` uses and `drift_check.nim` verifies against the real
##   private `growTargetCap`) -- its value at the end of a run IS the real
##   queue's final capacity, with no new tracking needed.
## - **growth events**: a new counter, incremented at each of the existing
##   `if q.len == cap: cap = growTargetCapShadow(cap)` growth checks
##   (`qoAddLast`'s branch) -- the exact same condition the real `addLast`
##   uses to decide whether to call `grow()`.
## - **physical wrap**: derived, not read from any private field. `addLast`
##   is the only op that advances the tail cursor; the real `slotIndex`
##   folds a monotonic logical position into `[0, cap)` by `pos and
##   (cap-1)` (`capMask`), so successive `addLast` calls land at
##   consecutive physical slots `0, 1, 2, ..., cap-1, 0, 1, ...` UNTIL
##   either (a) growth resets the backing array (a fresh, unwrapped `[0,
##   n)` layout by construction -- `grow()`'s own doc: `q.head = 0`,
##   `q.tail = uint(n)`), or (b) the physical index cycles from `cap-1`
##   back to `0` -- which is, by definition, a physical wrap of the ring
##   (only reachable at all if pops have freed low-index slots; without
##   any pops, `isFull` would trigger growth before tail could ever
##   revisit index 0). This file shadows that exact sequence with its own
##   `shadowTail`/`lastPushPhysIdx` locals (mirroring `slotIndex`'s `pos
##   and (cap-1)` via plain `mod cap`, valid since `cap` is always a power
##   of two here) and flags a wrap the moment a push's physical index is
##   LOWER than the previous push's within the same growth epoch --a
##   precise, not merely probabilistic, signal (tighter than the
##   `cumulative pops > 0 and cumulative pushes > initial cap` heuristic
##   the RFC slice's own scope note floats as a fallback: that heuristic
##   is a necessary-but-not-sufficient proxy -- e.g. many pushes after one
##   pop does not guarantee the physical cursor actually revisited index
##   0 -- whereas tracking the physical index sequence directly is exact).
type
  RunCoverage = object
    finalCap: int
    growthEvents: int
    wrapped: bool

var
  totalRuns = 0
  capHistogram = initTable[int, int]()
  growthEventsHistogram = initTable[int, int]()
  wrappedRuns = 0
  growth2PlusRuns = 0
  maxGrowthEventsSeen = 0

proc recordCoverage(rc: RunCoverage) =
  inc totalRuns
  capHistogram[rc.finalCap] = capHistogram.getOrDefault(rc.finalCap, 0) + 1
  growthEventsHistogram[rc.growthEvents] =
    growthEventsHistogram.getOrDefault(rc.growthEvents, 0) + 1
  if rc.wrapped: inc wrappedRuns
  if rc.growthEvents >= 2: inc growth2PlusRuns
  maxGrowthEventsSeen = max(maxGrowthEventsSeen, rc.growthEvents)

proc warmUpAndCaptureBaseline() =
  # One throwaway round through the exact same code path `prop` uses below,
  # so any one-time allocator/runtime-internal growth (observed empirically
  # on both MMs -- see module doc) happens BEFORE the baseline is captured,
  # not after.
  var q: CallbackQueue[LeakItem]
  var cap = 0
  for i in 0 ..< 64:
    if q.len == cap: cap = growTargetCapShadow(cap)
    q.addLast(LeakItem(id: i))
  while q.len > 0:
    discard q.popFirst()
  GC_fullCollect()
  baselineOcc = getOccupiedMem()
  echo "  baseline occupied mem (post warm-up, post GC_fullCollect): " & $baselineOcc & " bytes"

proc prop(ops: seq[QOpKind]) =
  var q: CallbackQueue[LeakItem]
  var cap = 0 # zero-value queue, per D9's lazy-init property
  var nextId = 0
  var liveCount = 0

  # Phase 3 (B-wave) coverage shadow state -- see the module-doc comment
  # above `RunCoverage` for the derivation. `shadowTail`/`lastPushPhysIdx`
  # only ever change inside `qoAddLast`; growth resets both, mirroring
  # `grow()`'s own `q.tail = uint(n)` reset exactly.
  var growthEvents = 0
  var shadowTail = 0
  var lastPushPhysIdx = -1
  var wrapped = false

  for op in ops:
    case op
    of qoAddLast:
      guardAsserts("addLast"):
        if q.len == cap:
          cap = growTargetCapShadow(cap)
          inc growthEvents
          shadowTail = liveCount # grow() resets tail to the live count
          lastPushPhysIdx = -1   # fresh backing array: no wrap history yet
        inc nextId
        q.addLast(LeakItem(id: nextId))
        inc liveCount
        let physIdx = shadowTail mod cap
        if lastPushPhysIdx >= 0 and physIdx < lastPushPhysIdx:
          wrapped = true
        lastPushPhysIdx = physIdx
        inc shadowTail
    of qoAddFirst:
      # Precondition-avoid, exactly like bisim_check.nim's addFirstEnabled:
      # a full-queue addFirst is deliberately exercised separately by
      # `runDefectUnwindChecks`, not smuggled into the leak-accounting loop
      # (which must stay clean on a correct implementation for its own
      # crash count to be a meaningful mutation-kill signal -- see
      # verify/README.md's Layer 5 methodology).
      if q.len < cap:
        guardAsserts("addFirst"):
          # Real name is `prependNoGrow` - see bisim_check.nim's
          # `doAddFirstReal` for the same pre-existing, W3-unrelated
          # rename note.
          inc nextId
          q.prependNoGrow(LeakItem(id: nextId))
          inc liveCount
    of qoPopFirst:
      if q.len > 0:
        guardAsserts("popFirst"):
          discard q.popFirst()
          dec liveCount

  # Phase 3 (B-wave): record this run's coverage observations before the
  # drain below (drain never grows the queue, so `cap`/`growthEvents`/
  # `wrapped` are already final at this point).
  recordCoverage(RunCoverage(finalCap: cap, growthEvents: growthEvents, wrapped: wrapped))

  # Force a full drain regardless of how the generated sequence ended --
  # "N random op cycles ending with full drain" (RFC 0001 S11 scope).
  while q.len > 0:
    guardAsserts("drain"):
      discard q.popFirst()
      dec liveCount

  doAssert liveCount == 0,
    "leak-accounting: live item count did not return to zero after full " &
    "drain (liveCount=" & $liveCount & ") -- a slot-vacating path lost track"

  GC_fullCollect()
  let occ = getOccupiedMem()
  doAssert occ <= baselineOcc + toleranceBytes,
    "leak-accounting: occupied memory did not return to baseline after " &
    "full drain -- occ=" & $occ & " baseline=" & $baselineOcc &
    " tolerance=" & $toleranceBytes &
    " (a fused-move dequeue conservation violation, or a real leak)"

proc runDefectUnwindChecks() =
  echo "--- Defect-unwind sequences (doAssert paths, panics:off) ---"

  block emptyPop:
    var q: CallbackQueue[LeakItem]
    var raised = false
    try:
      discard q.popFirst()
    except Defect:
      raised = true
    doAssert raised, "popFirst() on an empty queue must raise (doAssert), and be catchable"
    # Queue must remain fully usable afterward.
    q.addLast(LeakItem(id: 1))
    doAssert q.len == 1
    doAssert q.popFirst().id == 1
    doAssert q.len == 0
    echo "  popFirst() on empty: raised + caught, queue usable afterward -- OK"

  block fullAddFirst:
    var q = initCallbackQueue[LeakItem](2)
    q.addLast(LeakItem(id: 1))
    q.addLast(LeakItem(id: 2)) # queue now at its initial capacity (2)
    var raised = false
    try:
      q.prependNoGrow(LeakItem(id: 999)) # never grows -- must assert on full
    except Defect:
      raised = true
    doAssert raised, "addFirst() on a full queue must raise (doAssert), and be catchable"
    # Queue must remain fully usable afterward -- the two original items
    # still drain in order, and subsequent ops work normally.
    doAssert q.len == 2
    doAssert q.popFirst().id == 1
    doAssert q.popFirst().id == 2
    doAssert q.len == 0
    q.addLast(LeakItem(id: 3))
    doAssert q.popFirst().id == 3
    echo "  addFirst() on full: raised + caught, queue usable afterward -- OK"

echo "=== D9-V S11 Layer 4: coverage-guided fuzz + GC stress + leak accounting ==="
echo "(mm=" & mmName() & ", iterations=" & $fuzzIterations &
     ", maxOpsPerSeq=" & $maxOpsPerSeq & ", timeBudget=" & $fuzzTimeBudgetSeconds & "s)"

runDefectUnwindChecks()

warmUpAndCaptureBaseline()

let opStrat = frequency[QOpKind]([
  (5, just(qoAddLast)),
  (1, just(qoAddFirst)),
  (4, just(qoPopFirst)),
])
let seqStrat = lists(opStrat, minLen = 1, maxLen = maxOpsPerSeq)

echo "--- fuzzWith: randomized (IR-mutation) op-sequence exploration ---"
let settings = FuzzSettings(
  maxIterations: fuzzIterations,
  timeBudget: initDuration(seconds = fuzzTimeBudgetSeconds),
  seed: 0xC0FFEE'u64)
let t0 = epochTime()
let report = fuzzWith(seqStrat, prop, settings)
let elapsed = epochTime() - t0

echo "  iterations: " & $report.iterations
echo "  timed out: " & $report.timedOut
echo "  wall clock: " & elapsed.formatFloat(ffDecimal, 2) & "s"
echo "  crashes (irCrashes): " & $report.irCrashes.len

if report.irCrashes.len > 0:
  for i, cr in report.irCrashes:
    echo "    crash " & $i & ": " & cr.message
  doAssert false, "Layer 4 fuzz: " & $report.irCrashes.len &
    " finding(s) -- leak-accounting or crash assertion failed (see messages above)"

echo "--- Phase 3 (B-wave) coverage histogram (mm=" & mmName() & ", runs=" & $totalRuns & ") ---"
echo "  final capacity reached:"
var capsSeen: seq[int]
for c in capHistogram.keys: capsSeen.add c
capsSeen.sort()
for c in capsSeen:
  let n = capHistogram[c]
  echo "    cap=" & align($c, 6) & ": " & align($n, 6) & " runs (" &
       formatFloat(100.0 * float(n) / float(totalRuns), ffDecimal, 2) & "%)"

echo "  growth events per run:"
var gSeen: seq[int]
for g in growthEventsHistogram.keys: gSeen.add g
gSeen.sort()
for g in gSeen:
  let n = growthEventsHistogram[g]
  echo "    growthEvents=" & align($g, 3) & ": " & align($n, 6) & " runs (" &
       formatFloat(100.0 * float(n) / float(totalRuns), ffDecimal, 2) & "%)"
echo "    max growth events seen in a single run: " & $maxGrowthEventsSeen

let wrapPct = 100.0 * float(wrappedRuns) / float(totalRuns)
let growth2PlusPct = 100.0 * float(growth2PlusRuns) / float(totalRuns)
echo "  " & $wrappedRuns & "/" & $totalRuns & " runs (" &
     formatFloat(wrapPct, ffDecimal, 2) & "%) exercised at least one physical wrap"
echo "  " & $growth2PlusRuns & "/" & $totalRuns & " runs (" &
     formatFloat(growth2PlusPct, ffDecimal, 2) & "%) exercised >= 2 growth cycles"

echo "=== Layer 4: 0 crashes, 0 leak-accounting failures across " &
     $report.iterations & " iterations (mm=" & mmName() & ") ==="
