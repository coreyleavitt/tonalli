#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Spike coverage for the first-class `ContextVar[T]` key runtime. See
## .claude/rfc/0002-contextvars-firstclass-keys.handoff.md.

import std/[algorithm, sequtils, strutils, tables]
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

proc `$`(w: RenderWidget): string = "Widget(" & $w.id & ")"
  ## Gives t4/t25's "ref-with-$" fixture a deterministic rendering.

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

  test "dumpContext renders defaults and bound values across T shapes":
    let intKey = newContextVar("t4Int", 7)
    let widgetKey = newContextVar[RenderWidget]("t4Widget", nil)
    let blobKey = newContextVar("t4Blob", RenderBlob(3))

    block:
      let entries = dumpContext(currentContext())
      check entries.filterIt(it.name == "t4Int")[0].value == "7"
      check entries.filterIt(it.name == "t4Widget")[0].value == "nil"
      check entries.filterIt(it.name == "t4Blob")[0].value == "<no-$>"

    intKey.withValue(99):
      widgetKey.withValue(RenderWidget(id: 5)):
        blobKey.withValue(RenderBlob(11)):
          let entries = dumpContext(currentContext())
          check entries.filterIt(it.name == "t4Int")[0].value == "99"
          check entries.filterIt(it.name == "t4Widget")[0].value == "Widget(5)"
          check entries.filterIt(it.name == "t4Blob")[0].value == "<no-$>"

  test "two same-T keys are distinct":
    let k1 = newContextVar("t5Key", 1)
    let k2 = newContextVar("t5Key", 1)
    check k1 != k2

suite "contextkeys: ambient value and withValue":

  test "unbound defaulted read returns default":
    let k = newContextVar("t6Key", 11)
    check k.value == 11

  test "withValue binds: read inside body sees v":
    let k = newContextVar("t7Key", 0)
    k.withValue(42):
      check k.value == 42

  test "restore on normal exit: read after body sees default again":
    let k = newContextVar("t8Key", 0)
    k.withValue(42):
      discard
    check k.value == 0

  test "nested withValue same key: LIFO shadow, each exit restores its predecessor":
    let k = newContextVar("t9Key", 0)
    k.withValue(1):
      check k.value == 1
      k.withValue(2):
        check k.value == 2
        k.withValue(3):
          check k.value == 3
        check k.value == 2
      check k.value == 1
    check k.value == 0

  test "restore on exception: raise inside body, catch outside, read sees default":
    let k = newContextVar("t10Key", 0)
    expect ValueError:
      k.withValue(42):
        check k.value == 42
        raise newException(ValueError, "boom")
    check k.value == 0

  test "two same-T keys bound simultaneously each read back their own value":
    let k1 = newContextVar("t11Key1", 0)
    let k2 = newContextVar("t11Key2", 0)
    k1.withValue(1):
      k2.withValue(2):
        check k1.value == 1
        check k2.value == 2
      check k1.value == 1
      check k2.value == 0
    check k1.value == 0
    check k2.value == 0

  test "bindings of two different-T keys coexist":
    let ik = newContextVar("t12Int", 0)
    let sk = newContextVar("t12Str", "")
    ik.withValue(7):
      sk.withValue("hello"):
        check ik.value == 7
        check sk.value == "hello"
      check ik.value == 7
      check sk.value == ""
    check ik.value == 0
    check sk.value == ""

  test "withValue on a private key works the same":
    let k = newContextVar("t13Key", 0, private = true)
    check k.value == 0
    k.withValue(9):
      check k.value == 9
    check k.value == 0

suite "contextkeys: snapshot AsyncContext and []":

  test "currentContext() captured inside withValue outlives the binder":
    let k = newContextVar("t14Key", 0)
    var snap: AsyncContext
    k.withValue(42):
      snap = currentContext()
      check snap[k] == 42
    check snap[k] == 42

  test "snapshot captured before a later bind is unaffected by it":
    let k = newContextVar("t15Key", 0)
    let snap = currentContext()
    check snap[k] == 0
    k.withValue(99):
      check snap[k] == 0
    check snap[k] == 0

  test "snapshot == and hash: identity semantics, usable as a Table key":
    let a = currentContext()
    let b = currentContext()
    check a == b
    check hash(a) == hash(b)

    let k = newContextVar("t16Key", 0)
    k.withValue(1):
      let c = currentContext()
      check c != a

    var t = initTable[AsyncContext, string]()
    t[a] = "outer"
    check t[b] == "outer"

suite "contextkeys: must-bind Defect parity":

  test "unbound must-bind .value raises UnboundContextVarDefect with varName":
    let k = newContextVar[int]("t18Key")
    try:
      discard k.value
      check false
    except UnboundContextVarDefect as e:
      check e.varName == "t18Key"

  test "unbound must-bind ctx[cv] raises UnboundContextVarDefect, same fields":
    let k = newContextVar[int]("t19Key")
    let snap = currentContext()
    try:
      discard snap[k]
      check false
    except UnboundContextVarDefect as e:
      check e.varName == "t19Key"

  test "bound must-bind read returns the value on both paths, no raise":
    let k = newContextVar[int]("t20Key")
    k.withValue(5):
      check k.value == 5
      check currentContext()[k] == 5

  test "defaulted key ctx[cv] miss returns default, symmetric with .value":
    let k = newContextVar("t21Key", 11)
    check currentContext()[k] == 11
    check currentContext()[k] == k.value

suite "contextkeys: dumpContext and $":

  test "dumpContext on empty context: defaulted, must-bind, private semantics":
    let defaultedKey = newContextVar("t22Defaulted", 5)
    let mustBindKey = newContextVar[int]("t22MustBind")
    discard newContextVar("t22Private", 9, private = true)

    let entries = dumpContext(currentContext())

    let defaultedEntries = entries.filterIt(it.name == "t22Defaulted")
    check defaultedEntries.len == 1
    check defaultedEntries[0].bound == false
    check defaultedEntries[0].value == "5"

    let mustBindEntries = entries.filterIt(it.name == "t22MustBind")
    check mustBindEntries.len == 1
    check mustBindEntries[0].bound == false
    check mustBindEntries[0].value == "<unbound>"

    check not entries.anyIt(it.name == "t22Private")
    check defaultedKey.value == 5
    check mustBindKey.hasDefault == false

  test "dumpContext on a bound snapshot: bound=true, value rendered; fresh snapshot reverts to default":
    let k = newContextVar("t23Key", 1)
    var boundEntry: ContextVarEntry
    k.withValue(77):
      boundEntry = dumpContext(currentContext()).filterIt(it.name == "t23Key")[0]
    check boundEntry.bound == true
    check boundEntry.value == "77"

    let freshEntry = dumpContext(currentContext()).filterIt(it.name == "t23Key")[0]
    check freshEntry.bound == false
    check freshEntry.value == "1"

  test "`$` format parity and sorted order":
    let zKey = newContextVar("t24Zeta", 1)
    let aKey = newContextVar("t24Alpha", 2)
    let mKey = newContextVar("t24Mid", 3)
    zKey.withValue(10):
      aKey.withValue(20):
        mKey.withValue(30):
          let ctx = currentContext()
          let s = $ctx
          check s[0] == '{'
          check s[^1] == '}'
          check s.contains("t24Alpha: 20")
          check s.contains("t24Mid: 30")
          check s.contains("t24Zeta: 10")
          check s.find("t24Alpha") < s.find("t24Mid")
          check s.find("t24Mid") < s.find("t24Zeta")

          var names: seq[string]
          for entry in dumpContext(ctx):
            names.add entry.name
          check names == sorted(names)

  test "render parity: ref-with-$, ref nil default, $-less distinct, plain int":
    let refKey = newContextVar[RenderWidget]("t25Ref", RenderWidget(id: 3))
    let nilKey = newContextVar[RenderWidget]("t25Nil", nil)
    let blobKey = newContextVar("t25Blob", RenderBlob(4))
    let intKey = newContextVar("t25Int", 8)

    block:
      let entries = dumpContext(currentContext())
      check entries.filterIt(it.name == "t25Ref")[0].value == "Widget(3)"
      check entries.filterIt(it.name == "t25Nil")[0].value == "nil"
      check entries.filterIt(it.name == "t25Blob")[0].value == "<no-$>"
      check entries.filterIt(it.name == "t25Int")[0].value == "8"

    refKey.withValue(RenderWidget(id: 9)):
      nilKey.withValue(RenderWidget(id: 1)):
        blobKey.withValue(RenderBlob(2)):
          intKey.withValue(41):
            let entries = dumpContext(currentContext())
            check entries.filterIt(it.name == "t25Ref")[0].value == "Widget(9)"
            check entries.filterIt(it.name == "t25Nil")[0].value == "Widget(1)"
            check entries.filterIt(it.name == "t25Blob")[0].value == "<no-$>"
            check entries.filterIt(it.name == "t25Int")[0].value == "41"

when defined(chronosDebug):
  suite "contextkeys: chronosDebug construction lock":

    test "newContextVar after lockContextVarConstruction() asserts":
      lockContextVarConstruction()
      expect AssertionDefect:
        discard newContextVar("t26AfterLock", 1)
