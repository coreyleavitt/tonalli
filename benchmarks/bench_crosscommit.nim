#                Chronos Benchmark Suite
#            (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Cross-commit comparison harness (RFC 0001 D6, promoted at S8 from the
## round-1 prototype that lived at `build/bench.nim`).
##
## **Base-compatibility requirement.** This file imports plain `chronos`
## only -- nothing from `chronos/contextvars` -- so it compiles and runs
## *unmodified* against both the pinned pre-substrate base (b71392a) and
## any commit in this series. That property is deliberate, not
## incidental: the intra-commit harness (`bench_contextvars.nim`) can
## only measure a delta *within* one checkout (RFC 0001 D6's "structural
## blind spot" -- any cost paid identically by both its unused/bound
## arms cancels out of that comparison, no matter how large). Only a
## true cross-commit run, same file, same flags, two checkouts, catches
## that class of regression -- it is what caught S8's original refc
## construction-shape regression after five prior slices' intra-commit
## benches read flat. Do not add a `chronos/contextvars` import here;
## that would silently break comparability against the base checkout.
##
## Each metric is a single-process, single-pass average over many
## iterations (no internal trial loop, no median-of-N) -- one run of
## the compiled binary is one *trial*. The standing protocol (RFC 0001
## D6) generates a distribution by running the binary itself multiple
## times, alternating checkouts, not by looping inside the program:
##
##   1. Check out base commit b71392a into a second worktree, e.g.
##      `build/base` (`build/` is gitignored, so this file's header is
##      the durable record of the procedure -- nothing under `build/`
##      persists across a clean checkout). Caution: plain `git` commands
##      run *inside* `build/base` report the outer worktree's HEAD (the
##      checkout has no `.git` of its own) -- verify the snapshot by
##      diffing files against `git show b71392a:<path>`, never by
##      `git log` from within it.
##   2. Build this file identically in both checkouts, once per memory
##      manager, with the base-compat rule (import plain `chronos` only)
##      guaranteeing it compiles unmodified in `build/base`:
##      `nim c -d:release --mm:<orc|refc> --skipParentCfg --skipUserCfg
##      --outdir:build --nimcache:build/nimcache/$projectName
##      benchmarks/bench_crosscommit`.
##   3. Run the two resulting binaries **genuinely interleaved**
##      (base, head, base, head, ...) -- never batched one side then the
##      other, which reintroduces exactly the systemic drift
##      interleaving exists to rule out. Label every trial in the log.
##      13 trials per side for `callSoon fire` (the primary bellwether --
##      the tightest, least-diluted measurement of the
##      construction+enqueue+dequeue path); 9 per side for
##      `future create/await` and `sleepAsync(0) chain`. Judge pass/fail
##      per MM independently; the primary criterion is min-max range
##      non-overlap across the interleaved trials -- medians and the
##      head/base ratio are reported for trend only and never gate by
##      themselves (this container's documented ~30% same-code swings
##      make a bare ratio threshold fragile at these sample sizes).
##      Struct-size and memory rows are context, pinned independently by
##      guardrails, never part of the distributional test.
##
## This file performs one trial for a single checkout/MM combination;
## steps 1 and 3's repetition and interleaving are external to it, done
## once per slice that touches the dispatcher's construction or fire
## sites (S3-S6, S8 per RFC 0001 §6) and reported in RFC §1.
##
## Run via `nimble benchmarks` (release, both benchmarks/bench_*.nim) or
## directly:
##   nim c -d:release --mm:orc  -r benchmarks/bench_crosscommit
##   nim c -d:release --mm:refc -r benchmarks/bench_crosscommit

import ../chronos
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
