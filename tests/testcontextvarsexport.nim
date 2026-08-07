#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Cross-module test for the `contextVar` macro's export-marker
## semantics: `var name*: T = v` must produce an exported reader/binder
## pair, while `var name: T = v` (no star) must produce a module-private
## pair that is unreachable from an importing module.
##
## Uses a real second module (`contextvarsexportfixture.nim`) rather than
## same-module `declared()` checks, since visibility only differs
## across module boundaries.

import unittest2
import ../chronos/contextvars  # currentContext, AsyncContext
import ./contextvarsexportfixture

{.used.}

static:
  doAssert declared(exportedVar),
    "starred contextVar's reader must be reachable from an importing module"
  doAssert declared(withExportedVar),
    "starred contextVar's binder must be reachable from an importing module"
  doAssert not declared(privateVar),
    "non-starred contextVar's reader must NOT be reachable from an " &
    "importing module"
  doAssert not declared(withPrivateVar),
    "non-starred contextVar's binder must NOT be reachable from an " &
    "importing module"
  doAssert not declared(setExportedVar),
    "the macro must not generate an imperative binder — binding is " &
    "block-scoped (`withName`) only; see " &
    "testcontextvarssurface.nim for the rationale"
  doAssert compiles(exportedVar(currentContext())),
    "a starred arm's SNAPSHOT reader (`name(ctx: AsyncContext)`) must " &
    "also be reachable from an importing module — export-marker " &
    "semantics apply uniformly to both reader overloads"
  doAssert not compiles(privateVar(currentContext())),
    "a non-starred arm's snapshot reader must NOT be reachable from " &
    "an importing module either"

suite "contextvars: export marker (cross-module)":

  test "starred var's reader/binder are callable from another module":
    withExportedVar(42):
      check exportedVar() == 42
    check exportedVar() == 1

  test "starred var's snapshot reader is callable from another module":
    withExportedVar(7):
      let snap = currentContext()
      check exportedVar(snap) == 7

  test "non-starred arm is invisible to dumpContext from an importing module":
    # privateVar is registered (if at all) from contextvarsexportfixture.nim,
    # not here — the module-private contract requires it to be absent from
    # this module's dumpContext output too, not just unreachable by name.
    let entries = dumpContext(currentContext())
    for e in entries:
      check e.name != "privateVar"

  test "starred arm IS visible to dumpContext from an importing module":
    # Control: proves the check above isn't vacuous (registration works
    # at all across the module boundary for the starred sibling arm).
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "exportedVar":
        found = true
    check found

  test "compile-time guardrails passed":
    # Reaching this line means every `static:` check above passed.
    check true
