#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Single-binary driver for the contextvars suites that cannot share a
## process with tests/testall.nim, or with each other in the wrong order:
##
## - tests/testcontextvarsleakguard.nim lets an AssertionDefect escape
##   poll() under chronosDebug, leaving the dispatcher unsound for any
##   suite sharing that binary afterward.
## - tests/testcontextvarscrossthread.nim constructs a key from a second
##   thread and must run before the lock is engaged, since the lock
##   makes every construction in the process assert, including its own
##   control construction on the main thread.
## - tests/testcontextvarslock.nim's chronosDebug construction lock is
##   one-way for the process's lifetime: once engaged, every later
##   `newContextVar`/`newRequiredContextVar` call in the process asserts,
##   so it must run last.
##
## Importing all three here — rather than three separate nimble steps —
## collects them into one binary while keeping each a readable,
## independently-runnable unit. unittest2 defers a `test`'s body to
## program-exit time, run suite-by-suite in the order each suite's first
## `test` was *registered* — and registration happens as each imported
## module's own top-level code runs. For three sibling imports with no
## dependency between them, that registration runs in the imports'
## textual order below (confirmed empirically: a `suite`/`test` written
## inline in *this* file, rather than in an imported module, always
## registers after every import above it, regardless of source position —
## Nim runs a program's direct imports to completion before any of the
## importing module's own top-level statements, which is why the ordering
## contract here is expressed entirely through import order, not through
## interleaved local code).
import ./testcontextvarsleakguard
import ./testcontextvarscrossthread
import ./testcontextvarslock
