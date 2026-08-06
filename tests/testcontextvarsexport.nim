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
## Uses a real second module (`contextvarshelper.nim`) rather than
## same-module `declared()` checks, since visibility only differs
## across module boundaries.

import unittest2
import ./contextvarshelper

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

suite "contextvars: export marker (cross-module)":

  test "starred var's reader/binder are callable from another module":
    withExportedVar(42):
      check exportedVar() == 42
    check exportedVar() == 1

  test "compile-time guardrails passed":
    # Reaching this line means every `static:` check above passed.
    check true
