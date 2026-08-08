#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Spike coverage for the first-class `ContextVar[T]` key runtime. See
## .claude/rfc/0002-contextvars-firstclass-keys.handoff.md.

import unittest2
import ../chronos/internal/contextkeys

{.used.}

type
  RenderWidget = ref object
    id: int

  RenderBlob = distinct int
    ## Genuinely `$`-less on Nim >=2.x: a plain `object` is NOT
    ## `$`-less there — `std/objectdollar` auto-derives `$` for every
    ## object type, so `when compiles($v)` is unconditionally true for
    ## record-style fixtures. A `distinct` type without a borrowed `$`
    ## is what actually exercises the placeholder branch.

suite "contextkeys: key construction and registry":

  test "defaulted key stores name, hasDefault, and registers":
    let k = newContextVar("t1Key", 42)
    check k.name == "t1Key"
    check k.hasDefault == true
    var found = false
    for rv in registeredVars():
      if rv == ContextVarBase(k):
        found = true
    check found

  test "private key does not register":
    let k = newContextVar("t2Key", 42, private = true)
    check k.private == true
    var found = false
    for rv in registeredVars():
      if rv == ContextVarBase(k):
        found = true
    check not found

  test "must-bind arity has hasDefault false":
    let k = newContextVar[int]("t3Key")
    check k.hasDefault == false

  test "render hook renders defaults across T shapes":
    let intKey = newContextVar("t4Int", 7)
    check renderDefault(intKey) == "7"

    let widgetKey = newContextVar[RenderWidget]("t4Widget", nil)
    check renderDefault(widgetKey) == "nil"

    let blobKey = newContextVar("t4Blob", RenderBlob(3))
    check renderDefault(blobKey) == "<no-$>"

  test "two same-T keys are distinct":
    let k1 = newContextVar("t5Key", 1)
    let k2 = newContextVar("t5Key", 1)
    check k1 != k2
