#                  Tonalli Test Suite
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## Fixed-seed fixture for RFC 0003 3.8/S9b's cross-platform identity
## check: one deterministic `simulate()` run (a sim-legal contextvars
## binding across an await, alongside the same readiness-batch shape
## `tests/testsimulation.nim`'s pre-#703 fixture uses) whose decision
## log is byte-identical for the same seed on every platform (invariant
## 2). Not a unittest2 suite: the manually-dispatched CI job runs this
## on two platforms and diffs the resulting trace files directly: a
## divergence anywhere in the pipeline (oracle, clock, engine, id/digest
## stringification) shows up as a nonzero diff, not a parsed assertion.

import std/os
import ../tonalli
import ../tonalli/simulation
import ../tonalli/contextvars

const identitySeed = 0xC0FFEE'u64

let identityInt = newContextVar("simIdentityInt", 0)

simulate(seed = identitySeed):
  # The batch order between fdA/fdB is itself one of the oracle
  # decisions under comparison (RFC 0003 3.3): whichever order
  # `RandomOracle(identitySeed)` picks, both platforms must pick the
  # same one and log it identically, so nothing here asserts on it.
  let disp = getThreadDispatcher()
  var fired = 0
  let fdA = disp.mintSimFd()
  let fdB = disp.mintSimFd()
  discard addReader2(fdA, proc(arg: pointer) {.gcsafe, raises: [].} =
    inc fired)
  discard addReader2(fdB, proc(arg: pointer) {.gcsafe, raises: [].} =
    inc fired)
  discard disp.simMarkReady(fdA, SimReadyDirection.Read)
  discard disp.simMarkReady(fdB, SimReadyDirection.Read)

  identityInt.withValue(42):
    await sleepAsync(1.milliseconds)
    if identityInt.value != 42:
      raise newException(ValueError,
        "identity fixture: binding lost across await")

  if fired != 2:
    raise newException(ValueError,
      "identity fixture: expected both readiness callbacks to fire, got " &
      $fired)

# `simTracePath` (chronos/simulation.nim) is private; this reproduces its
# formula exactly rather than exporting it solely for this fixture's sake.
let tracePath = getTempDir() / "chronos-sim" / ("seed-" & $identitySeed & ".ndjson")
echo "IDENTITY_TRACE_PATH=" & tracePath
