#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## This file pins chronos's chronosDebug context-corruption detection net
## layer by layer: `withRestoredContext`'s identity-arm postcondition
## assert (chronos/futures.nim, ~231-236), and the restore arm's
## unconditional `finally` self-heal (same file, ~237-240).
##
## The cross-batch guard in `processCallbacks`
## (chronos/internal/asyncengine.nim, ~262-267) is deliberately NOT pinned
## here. Every per-callback dispatch path already runs through
## `withRestoredContext`, whose two arms cover corruption completely: the
## identity arm asserts on any divergence, the restore arm's `finally`
## silently repairs it regardless of what the callback did. The cross-batch
## guard is therefore unreachable from any current callback and exists
## purely as defense-in-depth against a future dispatch path that bypasses
## `withRestoredContext`. No test can isolate it without introducing such a
## path, which this suite will not do.
##
## Split out like tests/testcontextvarslock.nim rather than folded into
## testall.nim: the identity-arm case leaves an escaped AssertionDefect (and
## a stray, disconnected context node) behind, which would leave the
## dispatcher unsound for every other suite sharing that binary. It is
## wired as its own step in chronos.nimble's `test` task instead. The net
## itself only exists under `chronosDebug`, so every test here skips
## cleanly without it.

import std/strutils
import unittest2
import ../chronos/contextvars
import ../chronos/internal/contextnode
  # Whitebox: the identity-arm case constructs a bare `ContextNodeBase`
  # directly, which `chronos/contextvars.nim` does not expose.
import ../chronos/futures
  # Whitebox: `currentAsyncContext` is the threadvar the net inspects, and
  # `withRestoredContext` is the template under test; neither is reachable
  # through `import chronos`.
import ../chronos
  # Brings in `callSoon`/`poll`.

{.used.}

let leakGuardVar {.contextVar.} = 0

suite "contextvars: chronosDebug context-corruption detection net":

  test "control: a callback that binds and unwinds through withValue trips nothing":
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

  test "identity-arm layer: withRestoredContext's postcondition assert fires when its body corrupts currentAsyncContext":
    when defined(chronosDebug):
      # Called directly rather than through callSoon+poll(): processCallbacks'
      # own chronosDebug batch guard wraps every dispatch in a try/finally
      # whose doAssert, given this same corruption, also fails - and when a
      # second doAssert fails while the first is still unwinding, Nim's
      # finally semantics let the second's Defect replace the first. Routed
      # through poll(), this case would therefore only ever surface the
      # batch guard's message, not the identity arm's - confirmed empirically
      # before writing this test. Calling withRestoredContext directly is
      # the only way to observe the identity arm's own assert in isolation.
      let ambient = currentAsyncContext
      var caught = false
      try:
        withRestoredContext(ambient):
          currentAsyncContext = ContextNodeBase()
      except AssertionDefect as e:
        caught = true
        check "identity arm violated" in e.msg
      check caught
      currentAsyncContext = ambient
    else:
      skip()

  test "restore-arm layer: a captured-context callback that corrupts currentAsyncContext is healed by the finally, no Defect escapes":
    when defined(chronosDebug):
      let preAmbient = currentAsyncContext
      var ran = false
      proc corruptingRestoreCb(udata: pointer) {.gcsafe, raises: [].} =
        currentAsyncContext = ContextNodeBase()
        ran = true

      leakGuardVar.withValue(2):
        # Scheduled inside withValue so capturingCallback embeds a real,
        # non-nil chain - the restore arm only runs when the captured
        # context differs from the ambient ready to receive it.
        callSoon(corruptingRestoreCb, nil)

      poll()
      check ran
      check currentAsyncContext == preAmbient
    else:
      skip()
