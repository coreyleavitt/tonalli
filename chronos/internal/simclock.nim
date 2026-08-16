#
#                     Tonalli
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## The simulation clock: a thread-local, monotone nanosecond counter that
## `chronos/timer.nim`'s `Moment.now()` consults under `-d:chronosSimulation`
## in place of a real clock read.
##
## Leaf module: no chronos imports, so `timer.nim` (which needs `Moment`)
## and `chronos/internal/simengine.nim` (which advances the counter at
## `decideTime`) can both import it without an import cycle between them.

{.push raises: [], gcsafe.}

const
  simClockAnchorNanoseconds* = 1_577_836_800_000_000_000'i64
    ## 2020-01-01T00:00:00Z, epoch nanoseconds. Activation seeds the
    ## counter here rather than at zero or a runtime snapshot: `Moment`'s
    ## public epoch accessors treat the value as literal epoch time, and
    ## a run's decision log must be byte-identical across runs of the
    ## same seed.

var
  simClockActiveVar {.threadvar.}: bool
  simClockCounter {.threadvar.}: int64

proc isSimClockActive*(): bool {.inline.} =
  simClockActiveVar

proc simClockNanoseconds*(): int64 {.inline.} =
  simClockCounter

proc activateSimClock*() {.inline.} =
  simClockCounter = simClockAnchorNanoseconds
  simClockActiveVar = true

proc deactivateSimClock*() {.inline.} =
  simClockActiveVar = false

proc setSimClockNanoseconds*(value: int64) {.inline.} =
  simClockCounter = value
