#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Private mechanism backing the deterministic simulation substrate's
## dispatcher fork: the fd provenance table and its minting counter, the
## reserved barrier error code, and `SimBarrierError`.
##
## Imported by `chronos/internal/asyncengine.nim` under
## `-d:chronosSimulation`; this module never imports it back, so a
## simulated `Dispatcher`'s construction fork and provenance-guarded
## touch sites are the only consumers of the types below at this slice.

{.push raises: [], gcsafe.}

import std/sets
import ../oserrno

type
  SimBarrierError* = object of CatchableError
    ## Raised where a call site's signature can carry a typed error: a
    ## simulated dispatcher's fd provenance guard was crossed by a real
    ## fd, or a cross-thread entry point incompatible with simulation
    ## (`wake()`, `handle()`) was reached. Deliberately not a subtype of
    ## `AsyncError`, so an existing `except AsyncError` handler cannot
    ## silently swallow a hermeticity violation.

  SimEngineState* = ref object
    ## The sim-mode run state carried on a simulated `Dispatcher`: the
    ## fd provenance table, populated at mint time and consulted by
    ## every registration/teardown touch site before it acts on a fd,
    ## and the counter that mints it.
    endpoints: HashSet[int]
    nextFdValue: int

const
  SimBarrierCode* = OSErrorCode(1_397_835_586'i32)
    ## Reserved `OSErrorCode`, outside every platform's errno range
    ## ("SIMB" packed as ASCII bytes). A provenance-guarded touch site
    ## under simulation returns `err(SimBarrierCode)` through its
    ## unchanged `Result` signature instead of touching a real fd or a
    ## nil selector.

proc newSimEngineState*(startValue: int = 0): SimEngineState =
  SimEngineState(endpoints: initHashSet[int](), nextFdValue: startValue)

proc mintSimFd*(state: SimEngineState): int =
  ## Mints the next sim-owned fd-domain id and records it in the
  ## endpoint table. Skips `-1`, the representation shared by
  ## `osdefs.INVALID_SOCKET` and `osdefs.INVALID_HANDLE_VALUE` on every
  ## platform, so a minted id can never equal a sentinel value a
  ## teardown path `doAssert`s against directly.
  result = state.nextFdValue
  if result == -1:
    inc result
  state.nextFdValue = result + 1
  state.endpoints.incl(result)

proc ownsSimFd*(state: SimEngineState, value: int): bool =
  ## The fd provenance guard's membership test: `true` only for ids this
  ## run minted. Deliberately not a numeric-range partition - minted ids
  ## share the OS fd domain with kernel-assigned fds and cannot be
  ## soundly separated by value.
  value in state.endpoints

proc isSimBarrier*(code: OSErrorCode): bool {.inline.} =
  code == SimBarrierCode

proc raiseIfSimBarrier*(code: OSErrorCode) {.raises: [SimBarrierError].} =
  if isSimBarrier(code):
    raise newException(SimBarrierError,
      "simulation barrier: a provenance-guarded call reached a real " &
      "OS resource under -d:chronosSimulation")
