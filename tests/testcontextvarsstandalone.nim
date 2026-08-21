#                Tonalli Test Suite
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## Driver for the contextvars suites that cannot share a process with
## tests/testall.nim, or with each other:
##
## - tests/testcontextvarsleakguard.nim lets an AssertionDefect escape
##   poll() under tonalliDebug, leaving the dispatcher unsound for any
##   suite sharing that binary afterward.
## - tests/testcontextvarscrossthread.nim constructs a key from a second
##   thread and must not run after the lock is engaged, since the lock
##   makes every construction in the process assert, including its own
##   control construction on the main thread.
## - tests/testcontextvarsrecorderdeath.nim's full scenario needs a
##   process where no key has been constructed yet, so its worker thread
##   is the one that records; it must run before the lock is engaged for
##   the same reason as the cross-thread suite, and after the
##   leak-guard/cross-thread suites so their main-thread construction
##   has already claimed the recorder in this mode, exercising its
##   degraded branch instead — which orchestrate mode's per-suite
##   process avoids, giving it the full scenario there.
## - tests/testcontextvarslock.nim's tonalliDebug construction lock is
##   one-way for the process's lifetime: once engaged, every later
##   `newContextVar`/`newRequiredContextVar` call in the process asserts.
##
## Four invocation modes, selected by argv:
##
## - No arguments: all four suites run in one process, in the import
##   order below (dev convenience). Import order is load-bearing only in
##   this mode.
## - `list`: prints the four suite filters below, one per line, then
##   exits 0. The nimble test task dispatches each suite as its own
##   process (mirroring `orchestrate` below) so mobile legs route
##   through the adb/simctl indirection instead of executing a
##   cross-compiled binary directly; `list` lets the task's hardcoded
##   suite names be checked against this file on the desktop legs that
##   can run the binary. unittest2 prints its own suite headers as an
##   unconditional side effect of importing the four suites below - that
##   happens before any code in this file runs, so `list`'s output is
##   these four lines plus unittest2's own noise around them, not the
##   four lines alone; the nimble-side check looks for the four names
##   rather than expecting output equality.
## - `orchestrate`: this process becomes a parent that spawns itself once
##   per suite, each child given `"<suite name>::*"` as its sole argument
##   — a unittest2 filter that runs only that suite — so isolation is by
##   construction (separate processes) rather than by import order. Kept
##   as a desktop-only dev convenience now that the nimble task
##   dispatches suites itself; mobile builds exclude std/osproc and
##   reject this mode. `orchestrate` also doubles as a unittest2 filter in the
##   parent's own process: no test is named "orchestrate" and it
##   contains neither `::` nor `*`, so it matches nothing, and the
##   parent's own exit-time test run is an empty no-op that leaves the
##   aggregate exit code to the `quit` call below.
## - A `"<suite name>::*"` filter: passed through to unittest2 unchanged,
##   to run a single suite directly. One that ends in `::*` but names
##   none of the four suites is rejected with an error naming the known
##   suites, rather than silently matching nothing. Any other argument
##   (not ending in `::*`) still passes straight through to unittest2
##   unchanged.
import std/[os, strutils]
import ./testcontextvarsleakguard
import ./testcontextvarscrossthread
import ./testcontextvarsrecorderdeath
import ./testcontextvarslock

when not (defined(android) or defined(ios)):
  # Orchestrate mode is desktop-only: mobile targets run the per-suite
  # dispatch, and std/osproc does not compile against the Android NDK's
  # api-23 bionic (no posix_spawn).
  import std/osproc

const orchestrateArg = "orchestrate"
const listArg = "list"

const suiteNames = [
  contextVarsLeakGuardSuiteName,
  contextVarsCrossThreadSuiteName,
  contextVarsRecorderDeathSuiteName,
  contextVarsLockSuiteName,
]

if paramCount() >= 1 and paramStr(1) == listArg:
  for suiteName in suiteNames:
    echo suiteName
  quit(0)

if paramCount() >= 1 and paramStr(1) == orchestrateArg:
  when defined(android) or defined(ios):
    stderr.writeLine(
      "testcontextvarsstandalone: orchestrate mode is desktop-only; " &
      "run the suites individually via their \"<suite name>::*\" filters")
    quit(1)
  else:
    var allOk = true
    for suiteName in suiteNames:
      let child = startProcess(
        getAppFilename(), args = [suiteName & "::*"], options = {poParentStreams}
      )
      let code = waitForExit(child)
      close(child)
      echo "[testcontextvarsstandalone] ", suiteName, ": exit ", code
      if code != 0:
        allOk = false
    quit(if allOk: 0 else: 1)

if paramCount() >= 1 and paramStr(1).endsWith("::*"):
  var known = false
  for suiteName in suiteNames:
    if paramStr(1) == suiteName & "::*":
      known = true
      break
  if not known:
    stderr.writeLine("testcontextvarsstandalone: unknown suite filter: " & paramStr(1))
    stderr.writeLine("known suites:")
    for suiteName in suiteNames:
      stderr.writeLine("  " & suiteName & "::*")
    quit(1)
