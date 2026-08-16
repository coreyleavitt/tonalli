## Layer 4: coverage-guided fuzz + GC stress + leak accounting, and a
## dedicated Defect-unwind check.
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh fuzz`, once
## per MM (`MM=refc ./run.sh fuzz`, `MM=orc ./run.sh fuzz`).
##
## Imports the REAL `chronos/internal/callbackqueue.nim` directly (see
## `bisim_check.nim`'s module doc for why layers 3-5 do this and layers 1-2
## do not). This is the only layer that exercises the real allocator under
## a real memory manager -- proving the adopted fused-move dequeue does not
## leak, against the real `--mm:refc`/`--mm:orc` allocators rather than a
## ghost ledger.
##
## **Coverage-guided fuzz, honestly scoped.** `proptest/fuzz`'s `fuzzWith`
## is coverage-guided when the SUT carries `{.cover.}` instrumentation.
## `chronos/internal/callbackqueue.nim` is upstream-bound and must not
## carry any fork-only pragma or import, so it is never instrumented, and
## per `fuzz.nim`'s own module doc, this run degrades to a random
## IR-mutation fuzz over IR-mode's structural mutators, not
## edge-coverage-directed. Still real value: the IR mutators explore
## op-sequence SHAPE (lengths, op-kind boundaries, spliced sub-sequences
## from other corpus entries) more effectively than pure independent-draw
## random generation, and every `vInteresting` finding (a crash or a
## leak-accounting assertion) is a genuine harness failure either way.
##
## **Leak accounting.** Item = `ref object` (heap-allocated, GC-traced --
## the real allocator's own bookkeeping, not a ghost ledger). Each `prop`
## call: replay a generated op sequence against a FRESH real
## `CallbackQueue[LeakItem]`, force a full drain regardless of how the
## sequence ended, `GC_fullCollect()`, then assert `getOccupiedMem()` is
## within `toleranceBytes` of a baseline captured once at program start
## (after a warm-up round -- both MMs show a one-time bump on the first
## few GC-traced allocations as internal allocator structures grow, then
## plateau; warming up before sampling the baseline avoids mistaking that
## bump for drift). A genuine per-op leak accumulates roughly linearly
## with iterations and trips this assertion well before the fuzz budget
## is spent.
##
## **Defect-unwind sequences.** `popFirst()` on empty and `addFirst()` on a
## full queue both `doAssert`, raising a `Defect`. Under this fork's
## standing `panics:off` assumption, a `Defect` remains a catchable
## exception, so both are exercised directly here in
## `runDefectUnwindChecks`, confirming both (a) the assert fires and is
## catchable, and (b) the queue remains fully usable for subsequent ops
## afterward.

import std/[times, strutils, tables, algorithm]
import proptest
import ../tonalli/internal/callbackqueue

type
  LeakItem = ref object
    id: int

  QOpKind = enum
    qoAddLast, qoAddFirst, qoPopFirst

const
  maxOpsPerSeq = 300
  fuzzIterations = 50_000
    ## Budgeted for minutes, not hours. Each iteration replays up to
    ## `maxOpsPerSeq` queue ops plus a full drain and a `GC_fullCollect()`;
    ## 50,000 iterations x up to 300 ops is up to 15M queue operations per
    ## MM run.
  fuzzTimeBudgetSeconds = 90
    ## Safety net, not the primary stop condition (iterations is).
  toleranceBytes = 1_000_000
    ## 1 MB. Generous relative to one sequence's worst-case live set so
    ## runtime/allocator bookkeeping noise never false-positives, while
    ## still tight enough that a genuine per-op leak trips this well
    ## within the iteration budget.

proc mmName(): string =
  when defined(gcOrc): "orc"
  elif defined(gcArc): "arc"
  elif defined(gcRefc): "refc"
  else: "unknown"

template guardAsserts(where: string, body: untyped): untyped =
  ## Same discipline as `bisim_check.nim`/`bmc_ghost.nim`: convert an
  ## unexpected `doAssert`-raised `Defect` into a `CatchableError` so
  ## `fuzzWith`'s target still reports it as a finding (`vInteresting`),
  ## with `where` context added for a more useful crash report.
  try:
    body
  except Defect as verifyDefect:
    raise newException(ValueError,
      where & ": assertion fired -- " & verifyDefect.msg)

proc growTargetCapShadow(cap: int): int =
  ## See `bisim_check.nim`'s module doc: mirrors the real private
  ## `growTargetCap` exactly, verified by `drift_check.nim`.
  if cap == 0: 8 else: cap * 2

var baselineOcc: int
  ## Set once by `warmUpAndCaptureBaseline`, before the fuzz loop starts.

## --- Coverage accounting -------------------------------------------------
##
## Per-run observations, from public observations only -- no pragmas on
## `chronos/internal/callbackqueue.nim`, nothing reads its private fields.
##
## - **final capacity**: the existing `cap` shadow local, already tracked
##   per-`prop()`-call via `growTargetCapShadow` -- its value at the end
##   of a run IS the real queue's final capacity.
## - **growth events**: a counter incremented at each existing
##   `if q.len == cap: cap = growTargetCapShadow(cap)` growth check, the
##   same condition the real `addLast` uses to decide whether to grow.
## - **physical wrap**: derived, not read from any private field. `addLast`
##   is the only op that advances the tail cursor, landing at consecutive
##   physical slots `0, 1, 2, ..., cap-1, 0, 1, ...` until either growth
##   resets the backing array (fresh, unwrapped) or the physical index
##   cycles from `cap-1` back to `0` -- a physical wrap of the ring. This
##   file shadows that sequence with its own `shadowTail`/`lastPushPhysIdx`
##   locals and flags a wrap the moment a push's physical index is LOWER
##   than the previous push's within the same growth epoch -- an exact
##   signal, not a heuristic.
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
  # so any one-time allocator/runtime-internal growth happens BEFORE the
  # baseline is captured, not after.
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
  var cap = 0 # zero-value queue, lazy-init
  var nextId = 0
  var liveCount = 0

  # Coverage shadow state -- see the module-doc comment above
  # `RunCoverage` for the derivation. `shadowTail`/`lastPushPhysIdx` only
  # ever change inside `qoAddLast`; growth resets both, mirroring
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
      # (which must stay clean on a correct implementation for its crash
      # count to be a meaningful mutation-kill signal).
      if q.len < cap:
        guardAsserts("addFirst"):
          # Real name is `prependNoGrow` - see bisim_check.nim.
          inc nextId
          q.prependNoGrow(LeakItem(id: nextId))
          inc liveCount
    of qoPopFirst:
      if q.len > 0:
        guardAsserts("popFirst"):
          discard q.popFirst()
          dec liveCount

  # Record this run's coverage observations before the drain below (drain
  # never grows the queue, so `cap`/`growthEvents`/`wrapped` are already
  # final at this point).
  recordCoverage(RunCoverage(finalCap: cap, growthEvents: growthEvents, wrapped: wrapped))

  # Force a full drain regardless of how the generated sequence ended.
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

echo "=== Layer 4: coverage-guided fuzz + GC stress + leak accounting ==="
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

echo "--- Coverage histogram (mm=" & mmName() & ", runs=" & $totalRuns & ") ---"
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
