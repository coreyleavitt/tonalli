#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## The automatic cross-thread construction guard
## (chronos/contextvars.nim, `newContextVar`/`newRequiredContextVar`'s
## unconditional thread-generation check) — split out like
## tests/testcontextvarslock.nim and tests/testcontextvarsleakguard.nim,
## and imported between them from tests/testcontextvarsstandalone.nim:
## after the leak-guard suites (this file's own construction must not run
## inside a dispatcher a prior suite already left unsound), and before
## the lock suite (once engaged, the lock makes every construction in the
## process assert, including this file's own control construction).
##
## Actually constructing a context variable key from a second thread is
## a genuine `--mm:refc` GC hazard (see docs/src/contextvars.md,
## "Registry and key lifetime") — the guard this file tests is what
## turns that hazard into a caught `AssertionDefect` instead, and it now
## runs in every build, not only under `chronosDebug`.

import unittest2
import ../chronos/contextvars

{.used.}

suite "contextvars (raw key): cross-thread construction detection":

  test "newContextVar on a second thread trips the automatic thread-generation guard; registry stays intact":
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

  test "two sequential child threads each trip the guard, immune to OS thread-id recycling":
    # Under OS-TID identity, thread B could pass the guard whenever the
    # OS hands it thread A's just-recycled id — this test pins that a
    # second, later child thread is caught just as reliably as the
    # first, which a TID-based identity cannot guarantee.
    discard newContextVar("sequentialThreadsMainSeed", 0)

    proc constructOnChildThread(firedAddr: ptr bool) {.thread, nimcall.} =
      try:
        {.cast(gcsafe).}:
          discard newContextVar("sequentialThreadsKey", 1)
      except AssertionDefect:
        firedAddr[] = true

    var firedA = false
    var threadA: Thread[ptr bool]
    createThread(threadA, constructOnChildThread, addr firedA)
    joinThread(threadA)

    var firedB = false
    var threadB: Thread[ptr bool]
    createThread(threadB, constructOnChildThread, addr firedB)
    joinThread(threadB)

    check firedA
    check firedB
