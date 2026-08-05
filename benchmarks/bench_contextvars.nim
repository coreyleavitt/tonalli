#                Chronos Benchmark Suite
#            (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Continuation-local storage (contextvars) cost benchmark.
##
## Self-certifying, both-worlds design (RFC 0001 D6): every metric below
## runs twice in the *same* compiled binary, in the *same* process --
## once with the feature unused (no binder ever pushed, so the
## dispatcher's context guard always observes a nil ambient context) and
## once with a `contextVar` bound around the hot loop (a live binding
## chain the guard must save and restore). Each metric prints both
## numbers and the delta directly. A reviewer runs one command and sees
## both worlds in a single log; there is no cross-checkout diffing and
## no risk of unrelated inter-commit drift contaminating the comparison.
##
## Bias controls (RFC 0001 D6):
## - median-of-`Trials` per phase, computed automatically (sort the
##   sample array, take the middle element) -- never a manual best-of-3;
## - `GC_fullCollect()` runs before and after every phase, including the
##   pure-timing phases, not only the two memory metrics;
## - which world (unused vs. bound) runs first alternates metric to
##   metric (`runBothWorlds`/`runBothWorldsInt` flip a shared toggle),
##   so a fixed order cannot let warm-allocator or branch-predictor
##   carryover masquerade as signal.
##
## Chain-depth ladder: `contextVar` arms are compile-time macro
## emissions -- there is no runtime-parametrized "chain of depth N", and
## the chain-link privacy guardrail (see testcontextvarsguardrails.nim)
## forecloses hand-building chain nodes outside the macro. The ladder is
## therefore a fixed, hand-declared set of arms (`chain1` .. `chain16`)
## composed by a small compile-time unrolling macro (`withChainDepth`)
## rather than a parametrized sweep. Reading `chain1` at depth D walks D
## nodes: `chain1`'s binder is the outermost (and therefore oldest, and
## therefore furthest-from-head) of the nested `with` blocks, so it is
## the worst-case lookup for that depth.
##
## Timing method: `getMonoTime().ticks` differences are used directly as
## nanoseconds rather than going through `Duration`. This is the
## round-1 prototype's approach, valid because Nim's `std/monotimes` on
## POSIX is backed by `clock_gettime(CLOCK_MONOTONIC)`, whose `ticks`
## field is already nanoseconds -- true for every platform this
## benchmark runs on (container, Linux). It also sidesteps a name clash
## between chronos's own `Duration`/`milliseconds` (chronos/timer.nim,
## needed for `sleepAsync`) and `std/times`'s identically-named symbols.
##
## Cross-commit protocol (base-vs-series comparison; PR-description
## material, not reproduced by a single run of this file):
##   1. Check out base commit b71392a into a second worktree, e.g.
##      `build/base` (`build/` is gitignored, so this file header is the
##      durable record of the procedure -- nothing under `build/`
##      persists across a clean checkout).
##   2. Build and run this same bench file identically in both
##      checkouts, once per memory manager:
##      `nim c -d:release --mm:<orc|refc> --skipParentCfg --skipUserCfg
##      --outdir:build --nimcache:build/nimcache/$projectName
##      benchmarks/bench_contextvars.nim`.
##   3. Diff the two logs by hand. This file's own "unused" arm is the
##      series' intra-commit before/after datapoint; the base checkout's
##      (single-world, no contextvars code present) numbers are the
##      pre-substrate datapoint. Together they give the full
##      base -> series-unused -> series-bound progression that RFC 0001
##      S1 records in §1.
## This file performs step 2 for a single checkout only; steps 1 and 3
## are manual, repeated once per slice that touches the dispatcher
## (S3-S6 per RFC 0001 §6).
##
## Run via `nimble benchmarks` (release, both benchmarks/bench_*.nim) or
## directly:
##   nim c -d:release --mm:orc  -r benchmarks/bench_contextvars
##   nim c -d:release --mm:refc -r benchmarks/bench_contextvars

import std/[algorithm, macros, monotimes, strformat]

import ../chronos
import ../chronos/contextvars

{.used.}

# --- trial configuration ----------------------------------------------------

const
  Trials = 5
    ## Odd, so the median is a genuine sample rather than an average of
    ## two middle elements.
  CallSoonN = 300_000
  SleepChainN = 30_000
  FutureChurnN = 300_000
  MemPendingFutureN = 150_000
  MemQueuedCallbackN = 150_000
  ChainReadN = 300_000
  MixedBatchN = 300_000

# --- contextVar declarations -------------------------------------------------
# `benchVar`/`mixedVar` back the single-var metrics; `chain1` .. `chain16`
# back the depth ladder. All module-private (no `*`) -- this file is an
# executable, not a library.

contextVar:
  var benchVar: int = 0
  var mixedVar: int = 0
  var chain1: int = 0
  var chain2: int = 0
  var chain3: int = 0
  var chain4: int = 0
  var chain5: int = 0
  var chain6: int = 0
  var chain7: int = 0
  var chain8: int = 0
  var chain9: int = 0
  var chain10: int = 0
  var chain11: int = 0
  var chain12: int = 0
  var chain13: int = 0
  var chain14: int = 0
  var chain15: int = 0
  var chain16: int = 0

macro withChainDepth(depth: static int, body: untyped): untyped =
  ## Compose `depth` nested `with`-blocks (`withChain1` outermost through
  ## `withChain<depth>` innermost) around `body`. `depth` must be in
  ## 1..16 -- the hand-declared ladder above. Because `withChain1` is
  ## outermost, its node is pushed first and therefore sits furthest
  ## from the chain head once all `depth` binders are active: reading
  ## `chain1()` inside `body` is the depth-D worst case for
  ## `contextLookup`'s O(depth) walk.
  doAssert depth in 1 .. 16, "withChainDepth: depth out of the hand-declared ladder"
  result = body
  for i in countdown(depth, 1):
    result = newCall(ident("withChain" & $i), newLit(i), result)

# --- median-of-N trial infrastructure ----------------------------------------

proc median(samples: var seq[float]): float =
  samples.sort()
  samples[samples.len div 2]

proc medianInt(samples: var seq[int]): int =
  samples.sort()
  samples[samples.len div 2]

proc benchMedian(trials: int, fn: proc(): float {.closure.}): float =
  ## Run `fn` `trials` times, `GC_fullCollect`ing before and after every
  ## trial (not only around the memory metrics -- RFC 0001 D6), and
  ## return the median. `fn` is expected to return its own ns/op figure
  ## already normalized by iteration count.
  var samples = newSeq[float](trials)
  for i in 0 ..< trials:
    GC_fullCollect()
    samples[i] = fn()
    GC_fullCollect()
  median(samples)

proc benchMedianInt(trials: int, fn: proc(): int {.closure.}): int =
  var samples = newSeq[int](trials)
  for i in 0 ..< trials:
    GC_fullCollect()
    samples[i] = fn()
    GC_fullCollect()
  medianInt(samples)

var worldOrderBoundFirst = false
  ## Toggled by every `runBothWorlds`/`runBothWorldsInt` call so a fixed
  ## unused-then-bound order cannot make warm-allocator/branch-predictor
  ## carryover systematic across metrics (RFC 0001 D6).

proc reportFloat(name: string, unused, bound: float) =
  let delta = if unused == 0.0: 0.0 else: (bound - unused) / unused * 100.0
  echo &"{name:<34} unused={unused:10.2f} ns/op   bound={bound:10.2f} ns/op   delta={delta:+7.1f}%"

proc reportInt(name: string, unused, bound: int) =
  let delta = if unused == 0: 0.0 else: (bound - unused).float / unused.float * 100.0
  echo &"{name:<34} unused={unused:8} B/op     bound={bound:8} B/op     delta={delta:+7.1f}%"

proc runBothWorlds(name: string, unusedFn, boundFn: proc(): float {.closure.}) =
  var unused, bound: float
  if worldOrderBoundFirst:
    bound = benchMedian(Trials, boundFn)
    unused = benchMedian(Trials, unusedFn)
  else:
    unused = benchMedian(Trials, unusedFn)
    bound = benchMedian(Trials, boundFn)
  worldOrderBoundFirst = not worldOrderBoundFirst
  reportFloat(name, unused, bound)

proc runBothWorldsInt(name: string, unusedFn, boundFn: proc(): int {.closure.}) =
  var unused, bound: int
  if worldOrderBoundFirst:
    bound = benchMedianInt(Trials, boundFn)
    unused = benchMedianInt(Trials, unusedFn)
  else:
    unused = benchMedianInt(Trials, unusedFn)
    bound = benchMedianInt(Trials, boundFn)
  worldOrderBoundFirst = not worldOrderBoundFirst
  reportInt(name, unused, bound)

# --- metric 1: callSoon schedule+fire ----------------------------------------

proc benchCallSoonUnused(n: int): float =
  var count = 0
  proc cb(u: pointer) {.gcsafe, raises: [].} =
    inc count
  let start = getMonoTime().ticks
  var scheduled = 0
  while scheduled < n:
    let batch = min(10_000, n - scheduled)
    for i in 0 ..< batch:
      callSoon(cb, nil)
    inc scheduled, batch
    poll()
  while count < n:
    poll()
  (getMonoTime().ticks - start).float / n.float

proc benchCallSoonBound(n: int): float =
  var count = 0
  proc cb(u: pointer) {.gcsafe, raises: [].} =
    inc count
  withBenchVar(1):
    let start = getMonoTime().ticks
    var scheduled = 0
    while scheduled < n:
      let batch = min(10_000, n - scheduled)
      for i in 0 ..< batch:
        callSoon(cb, nil)
      inc scheduled, batch
      poll()
    while count < n:
      poll()
    result = (getMonoTime().ticks - start).float / n.float

# --- metric 2: sleepAsync(0) await chain --------------------------------------

proc benchSleepChainUnused(n: int): float =
  proc chain(): Future[void] {.async.} =
    for i in 0 ..< n:
      await sleepAsync(0.milliseconds)
  let start = getMonoTime().ticks
  waitFor chain()
  (getMonoTime().ticks - start).float / n.float

proc benchSleepChainBound(n: int): float =
  proc chain(): Future[void] {.async.} =
    withBenchVar(1):
      for i in 0 ..< n:
        await sleepAsync(0.milliseconds)
  let start = getMonoTime().ticks
  waitFor chain()
  (getMonoTime().ticks - start).float / n.float

# --- metric 3: future create/await -------------------------------------------

proc benchFutureChurnUnused(n: int): float =
  proc mk(): Future[int] {.async.} =
    return 1
  proc run(): Future[int] {.async.} =
    var acc = 0
    for i in 0 ..< n:
      acc += await mk()
    return acc
  let start = getMonoTime().ticks
  discard waitFor run()
  (getMonoTime().ticks - start).float / n.float

proc benchFutureChurnBound(n: int): float =
  proc mk(): Future[int] {.async.} =
    return 1
  proc run(): Future[int] {.async.} =
    var acc = 0
    withBenchVar(1):
      for i in 0 ..< n:
        acc += await mk()
    return acc
  let start = getMonoTime().ticks
  discard waitFor run()
  (getMonoTime().ticks - start).float / n.float

# --- metric 4: mem / pending future -------------------------------------------

proc benchMemPendingFutureUnused(n: int): int =
  var futs = newSeqOfCap[Future[void]](n)
  GC_fullCollect()
  let before = getOccupiedMem()
  for i in 0 ..< n:
    futs.add newFuture[void]("bench")
  result = (getOccupiedMem() - before) div n
  GC_fullCollect()
  for f in futs:
    f.complete()

proc benchMemPendingFutureBound(n: int): int =
  var futs = newSeqOfCap[Future[void]](n)
  GC_fullCollect()
  withBenchVar(1):
    let before = getOccupiedMem()
    for i in 0 ..< n:
      futs.add newFuture[void]("bench")
    result = (getOccupiedMem() - before) div n
  GC_fullCollect()
  for f in futs:
    f.complete()

# --- metric 5: mem / queued callback ------------------------------------------
#
# `callSoon` always schedules onto the *one* per-thread dispatcher's
# `Deque[AsyncCallback]` (chronos/internal/asyncengine.nim) -- there is
# no public constructor for a standalone `AsyncCallback` seq to measure
# in isolation (deliberate: only `userCallback`/`internalCallback` can
# build one, per D0's capture-discipline guardrails). A deque's backing
# buffer capacity only grows, never shrinks, so measuring this metric
# repeatedly (median-of-N) or back-to-back for both worlds on the same
# thread collapses to ~0 bytes/op after the first measurement warms the
# capacity -- an artifact of amortized growth, not signal (confirmed:
# an earlier draft of this file measured 0 B/op for both worlds here,
# for exactly this reason). Both worlds instead each get a freshly
# spawned OS thread, which chronos gives its own per-thread dispatcher
# (`{.threadvar.}`-rooted, same mechanism the cross-thread work in
# #694 relies on) starting from the same pristine initial capacity, so
# the two measurements are apples-to-apples. Single-shot per world (no
# median-of-N) is therefore the correct, not merely convenient, method
# for this one metric.

var queuedCallbackMemResult: int
  ## Written by `queuedCallbackMemThread` on its own thread, read on the
  ## main thread strictly after `joinThread` -- `joinThread` establishes
  ## the happens-before edge, so this is race-free despite being a plain
  ## global rather than an atomic.

proc queuedCallbackMemThread(bound: bool) {.thread, nimcall.} =
  var count = 0
  proc cb(u: pointer) {.gcsafe, raises: [].} =
    inc count
  GC_fullCollect()
  template measure() =
    let before = getOccupiedMem()
    for i in 0 ..< MemQueuedCallbackN:
      callSoon(cb, nil)
    queuedCallbackMemResult = (getOccupiedMem() - before) div MemQueuedCallbackN
  if bound:
    withBenchVar(1):
      measure()
  else:
    measure()
  GC_fullCollect()
  while count < MemQueuedCallbackN:
    poll()

proc benchMemQueuedCallbackFresh(bound: bool): int =
  var t: Thread[bool]
  createThread(t, queuedCallbackMemThread, bound)
  joinThread(t)
  queuedCallbackMemResult

# --- bound single-var steady state / chain-depth ladder ----------------------

proc benchChainReadUnused(n: int): float =
  var acc = 0
  let start = getMonoTime().ticks
  for i in 0 ..< n:
    acc += chain1()
  result = (getMonoTime().ticks - start).float / n.float
  doAssert acc == 0, "unbound chain1() must read the declared default"

proc benchChainReadBound(n: int, depth: static int): float =
  var acc = 0
  withChainDepth(depth):
    let start = getMonoTime().ticks
    for i in 0 ..< n:
      acc += chain1()
    result = (getMonoTime().ticks - start).float / n.float
  doAssert acc == n, "chain1() must read its bound value (1) at every depth"

# --- mixed bound/unbound batch (branch-predictor-hostile interleaving) -------

proc benchMixedBatch(n: int): float =
  var count = 0
  proc cb(u: pointer) {.gcsafe, raises: [].} =
    inc count
  let start = getMonoTime().ticks
  var scheduled = 0
  while scheduled < n:
    let batch = min(10_000, n - scheduled)
    for i in 0 ..< batch:
      if (scheduled + i) mod 2 == 0:
        callSoon(cb, nil)
      else:
        withMixedVar(1):
          callSoon(cb, nil)
    inc scheduled, batch
    poll()
  while count < n:
    poll()
  (getMonoTime().ticks - start).float / n.float

# --- report -------------------------------------------------------------------

proc runReport() =
  const mmName =
    when defined(gcOrc): "orc"
    elif defined(gcArc): "arc"
    elif defined(gcRefc): "refc"
    elif defined(gcMarkAndSweep): "markAndSweep"
    else: "unknown"
  echo &"chronos contextvars benchmark -- mm={mmName} release={defined(release)}"
  echo ""

  echo "-- struct sizes (reconciles RFC 0001 Sec.1 struct math) --"
  echo &"sizeof(AsyncCallback):        {sizeof(AsyncCallback)} bytes"
  block:
    let sizeofProbe = newFuture[void]("sizeof-probe")
    echo &"sizeof(Future[void] object): {sizeof(sizeofProbe[])} bytes"
    sizeofProbe.complete()
  echo ""

  echo "-- five Sec.1 metrics, both worlds (unused vs. one contextVar bound around the hot loop) --"
  runBothWorlds("callSoon schedule+fire",
    proc(): float = benchCallSoonUnused(CallSoonN),
    proc(): float = benchCallSoonBound(CallSoonN))
  runBothWorlds("sleepAsync(0) await chain",
    proc(): float = benchSleepChainUnused(SleepChainN),
    proc(): float = benchSleepChainBound(SleepChainN))
  runBothWorlds("future create/await",
    proc(): float = benchFutureChurnUnused(FutureChurnN),
    proc(): float = benchFutureChurnBound(FutureChurnN))
  runBothWorldsInt("mem / pending future",
    proc(): int = benchMemPendingFutureUnused(MemPendingFutureN),
    proc(): int = benchMemPendingFutureBound(MemPendingFutureN))
  block:
    # Single-shot, fresh-dispatcher-per-world -- see the comment above
    # `queuedCallbackMemThread` for why this metric cannot use the
    # shared median-of-N machinery.
    var unused, bound: int
    if worldOrderBoundFirst:
      bound = benchMemQueuedCallbackFresh(true)
      unused = benchMemQueuedCallbackFresh(false)
    else:
      unused = benchMemQueuedCallbackFresh(false)
      bound = benchMemQueuedCallbackFresh(true)
    worldOrderBoundFirst = not worldOrderBoundFirst
    reportInt("mem / queued callback", unused, bound)
  echo ""

  echo "-- bound single-var steady state + chain-depth ladder (contextLookup O(depth) walk) --"
  let unboundRead = benchMedian(Trials, proc(): float = benchChainReadUnused(ChainReadN))
  echo &"chain1() read, unbound (epsilon baseline)  {unboundRead:10.2f} ns/op"
  let depth1 = benchMedian(Trials, proc(): float = benchChainReadBound(ChainReadN, 1))
  echo &"chain1() read, bound, depth=1 (steady state){depth1:10.2f} ns/op"
  let depth4 = benchMedian(Trials, proc(): float = benchChainReadBound(ChainReadN, 4))
  echo &"chain1() read, bound, depth=4               {depth4:10.2f} ns/op"
  let depth16 = benchMedian(Trials, proc(): float = benchChainReadBound(ChainReadN, 16))
  echo &"chain1() read, bound, depth=16              {depth16:10.2f} ns/op"
  echo ""

  echo "-- mixed bound/unbound batch (branch-predictor-hostile interleaving) --"
  let mixed = benchMedian(Trials, proc(): float = benchMixedBatch(MixedBatchN))
  echo &"callSoon schedule+fire, alternating bound/unbound  {mixed:10.2f} ns/op"

when isMainModule:
  runReport()
