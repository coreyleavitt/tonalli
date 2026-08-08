#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## processCallbacks' chronosDebug cross-batch leak guard (chronos/internal/
## asyncengine.nim, `doAssert currentAsyncContext == chronosDebugPreBatch`)
## is exercised only by the correct-restore path everywhere else in the
## contextvars suites, so its own ability to fire is unverified. This file
## proves it does: a callback that overwrites `currentAsyncContext` without
## restoring it must trip the guard, with a correctly-restoring control
## case first to show the guard stays quiet on the happy path.
##
## Split out like tests/testcontextvarslock.nim rather than folded into
## testall.nim: the corrupting case leaves an escaped AssertionDefect (and
## a stray, disconnected context node) behind, which would leave the
## dispatcher unsound for every other suite sharing that binary. It is
## wired as its own step in chronos.nimble's `test` task instead. The guard
## itself only exists under `chronosDebug`, so both tests skip cleanly
## without it.

import unittest2
import ../chronos/contextvars
import ../chronos/internal/contextnode
  # Whitebox: the corrupting case constructs a bare `ContextNodeBase`
  # directly, which `chronos/contextvars.nim` does not expose.
import ../chronos/futures
  # Whitebox: `currentAsyncContext` is the threadvar the guard snapshots;
  # neither it nor its type is reachable through `import chronos`.
import ../chronos
  # Brings in `callSoon`/`poll`.

{.used.}

let leakGuardVar {.contextVar.} = 0

suite "contextvars: chronosDebug cross-batch leak guard":

  test "control: a callback that binds and unwinds through withValue does not trip the guard":
    when defined(chronosDebug):
      var ran = false
      proc goodCb(udata: pointer) {.gcsafe, raises: [].} =
        leakGuardVar.withValue(1):
          discard leakGuardVar.value
        ran = true

      callSoon(goodCb, nil)
      poll()
      check ran
    else:
      skip()

  test "a callback that overwrites currentAsyncContext without restoring trips the guard":
    when defined(chronosDebug):
      proc corruptingCb(udata: pointer) {.gcsafe, raises: [].} =
        currentAsyncContext = ContextNodeBase()

      callSoon(corruptingCb, nil)
      expect AssertionDefect:
        poll()
    else:
      skip()
