#                  Tonalli Test Suite
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## Tests for `chronos/internal/simclock.nim` (the leaf module holding the
## simulation clock state) and, under `-d:chronosSimulation`, the
## `Moment.now()` seam in `chronos/timer.nim` that consults it.

import unittest2
import ../tonalli/internal/simclock

when defined(chronosSimulation):
  import ../tonalli, ../tonalli/timer

{.used.}

suite "sim clock state":
  test "inactive by default":
    deactivateSimClock()
    check not isSimClockActive()

  test "activation seeds the fixed anchor":
    activateSimClock()
    check isSimClockActive()
    check simClockNanoseconds() == simClockAnchorNanoseconds
    deactivateSimClock()

  test "the counter can be moved independently of activation":
    activateSimClock()
    setSimClockNanoseconds(123_456_789'i64)
    check simClockNanoseconds() == 123_456_789'i64
    deactivateSimClock()

  test "deactivation clears the active flag but not the counter":
    activateSimClock()
    setSimClockNanoseconds(42'i64)
    deactivateSimClock()
    check not isSimClockActive()
    check simClockNanoseconds() == 42'i64

when defined(chronosSimulation):
  suite "sim clock seam (Moment.now())":
    test "an activated sim clock is read back exactly":
      activateSimClock()
      setSimClockNanoseconds(1_600_000_000_000_000_000'i64)
      let moment = Moment.now()
      deactivateSimClock()
      check moment.epochNanoSeconds == 1_600_000_000_000_000_000'i64

    test "an inactive sim clock falls back to the real clock":
      deactivateSimClock()
      let moment = Moment.now()
      check moment.epochNanoSeconds != simClockAnchorNanoseconds
