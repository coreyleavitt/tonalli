#
#                     Tonalli
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## Cross-commit comparison harness.
##
## **Base-compatibility requirement.** This file imports plain `chronos`
## only -- nothing from `chronos/contextvars` -- so it compiles and runs
## *unmodified* against both the pinned pre-substrate base (b71392a) and
## any commit in this series. This is what makes a true cross-commit run
## possible; the intra-commit harness (`bench_contextvars.nim`) can only
## measure a delta within one checkout, which cancels out any cost paid
## identically by both its arms. Do not add a `chronos/contextvars`
## import here; that would break comparability against the base checkout.
##
## Each metric is a single-process, single-pass average over many
## iterations -- one run of the compiled binary is one *trial*. The
## distribution comes from running the binary itself multiple times,
## alternating checkouts, not from looping inside the program:
##
##   1. Check out base commit b71392a into a second worktree, e.g.
##      `build/base`. Caution: plain `git` commands run *inside*
##      `build/base` report the outer worktree's HEAD (the checkout has
##      no `.git` of its own) -- verify the snapshot by diffing files
##      against `git show b71392a:<path>`, never by `git log` from
##      within it.
##   2. Build this file identically in both checkouts, once per memory
##      manager:
##      `nim c -d:release --mm:<orc|refc> --skipParentCfg --skipUserCfg
##      --outdir:build --nimcache:build/nimcache/$projectName
##      benchmarks/bench_crosscommit`.
##   3. Run the two resulting binaries **genuinely interleaved**
##      (base, head, base, head, ...), never batched one side then the
##      other. Judge pass/fail per MM independently by min-max range
##      non-overlap across the interleaved trials; medians and the
##      head/base ratio are reported for trend only and never gate by
##      themselves. Struct-size and memory rows are context, never part
##      of the distributional test.
##
## This file performs one trial for a single checkout/MM combination;
## steps 1 and 3's repetition and interleaving are external to it.
##
## Run via `nimble benchmarks` (release, both benchmarks/bench_*.nim) or
## directly:
##   nim c -d:release --mm:orc  -r benchmarks/bench_crosscommit
##   nim c -d:release --mm:refc -r benchmarks/bench_crosscommit

import ../tonalli
import std/[monotimes, strformat]

{.used.}

proc benchCallSoon(n: int): float =
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
  float(getMonoTime().ticks - start) / float(n)

proc benchSleepChain(n: int): float =
  proc chain(): Future[void] {.async.} =
    for i in 0 ..< n:
      await sleepAsync(0.milliseconds)
  let start = getMonoTime().ticks
  waitFor chain()
  float(getMonoTime().ticks - start) / float(n)

proc benchFutureChurn(n: int): float =
  proc mk(): Future[int] {.async.} =
    return 1
  proc run(): Future[int] {.async.} =
    var acc = 0
    for i in 0 ..< n:
      acc += await mk()
    return acc
  let start = getMonoTime().ticks
  discard waitFor run()
  float(getMonoTime().ticks - start) / float(n)

proc memPendingFutures(n: int): int =
  var futs = newSeqOfCap[Future[void]](n)
  GC_fullCollect()
  let before = getOccupiedMem()
  for i in 0 ..< n:
    futs.add newFuture[void]("m")
  let per = (getOccupiedMem() - before) div n
  for f in futs:
    f.complete()
  per

proc memQueuedCallbacks(n: int): int =
  var count = 0
  proc cb(u: pointer) {.gcsafe, raises: [].} =
    inc count
  GC_fullCollect()
  let before = getOccupiedMem()
  for i in 0 ..< n:
    callSoon(cb, nil)
  let per = (getOccupiedMem() - before) div n
  while count < n:
    poll()
  per

when isMainModule:
  echo &"sizeof(AsyncCallback): {sizeof(AsyncCallback)} bytes"
  echo &"callSoon fire:        {benchCallSoon(2_000_000):8.1f} ns/op"
  echo &"sleepAsync(0) chain:  {benchSleepChain(200_000):8.1f} ns/op"
  echo &"future create/await:  {benchFutureChurn(2_000_000):8.1f} ns/op"
  echo &"mem/pending future:   {memPendingFutures(1_000_000):8} bytes"
  echo &"mem/queued callback:  {memQueuedCallbacks(1_000_000):8} bytes"
