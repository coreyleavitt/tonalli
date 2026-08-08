#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## The automatic `chronosDebug` cross-thread construction guard
## (chronos/contextvars.nim, `newContextVar`/`newRequiredContextVar`'s
## unconditional thread-id check) — split out like
## tests/testcontextvarslock.nim and tests/testcontextvarsleakguard.nim,
## and imported between them from tests/testcontextvarsstandalone.nim:
## after the leak-guard suites (this file's own construction must not run
## inside a dispatcher a prior suite already left unsound), and before
## the lock suite (once engaged, the lock makes every construction in the
## process assert, including this file's own control construction).
##
## Actually constructing a context variable key from a second thread is
## a genuine `--mm:refc` GC hazard outside chronosDebug (see
## docs/src/contextvars.md, "Registry and key lifetime") — the guard
## this file tests is what turns that hazard into a caught
## `AssertionDefect` instead, so every test here is gated under
## `when defined(chronosDebug)` and skips cleanly without it.

import unittest2
import ../chronos/contextvars

{.used.}

suite "contextvars (raw key): chronosDebug cross-thread construction detection":

  test "newContextVar on a second thread trips the automatic thread-id guard; registry stays intact":
    when defined(chronosDebug):
      # Construct on the main thread first: the guard records whichever
      # thread constructs first as "the" thread, so without this, running
      # this file on its own (rather than after
      # tests/testcontextvarsleakguard.nim's own main-thread construction,
      # as happens in tests/testcontextvarsstandalone.nim) would race the
      # child thread below for that role instead of reliably exercising
      # it as the violator.
      discard newContextVar("crossThreadMainThreadSeed", 0)

      var fired = false

      proc constructOnOtherThread(firedAddr: ptr bool) {.thread, nimcall.} =
        try:
          {.cast(gcsafe).}:
            discard newContextVar("crossThreadKey", 1)
        except AssertionDefect:
          firedAddr[] = true

      var otherThread: Thread[ptr bool]
      createThread(otherThread, constructOnOtherThread, addr fired)
      joinThread(otherThread)

      check fired

      # The failed cross-thread construction must not have reached the
      # registry mutation: a subsequent main-thread construction still
      # succeeds, which would not be reliable if the guard fired only
      # after registerVar() already ran.
      let k = newContextVar("afterCrossThreadAttempt", 2)
      check k.value == 2
    else:
      skip()
