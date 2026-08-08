#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Behavior tests for chronos's continuation-local storage primitive —
## the `ContextVar[T]` key runtime. See chronos/contextvars.nim and
## docs/src/contextvars.md.
##
## Must run LAST among the contextvars test files (see tests/testall.nim):
## its `chronosDebug` construction-lock suite, at the bottom of this file,
## permanently locks `newContextVar` for the rest of the process.

import std/[algorithm, sequtils, strutils, tables]
import unittest2
import ../chronos/contextvars

{.used.}

# --- Scoped binding fixtures --------------------------------------------------

let tracerInt {.contextVar.} = 0
let tracerStr {.contextVar.} = "default"

# No `*` marker — module-private; value/binder must still work within
# this same module.
let privateOnlyVar {.contextVar.} = 0

# One starred, one not — each honors its own marker independently.
let mixedPublic* {.contextVar.} = 10
let mixedPrivate {.contextVar.} = 20

suite "contextvars: declaration + scoped binding":

  test "scoped binding visible inside body":
    tracerInt.withValue(42):
      check tracerInt.value == 42

  test "default value when no binding in scope":
    check tracerInt.value == 0

  test "binding reverts on normal block exit":
    tracerInt.withValue(42):
      discard
    check tracerInt.value == 0

  test "nested bindings see innermost; restore LIFO":
    tracerInt.withValue(1):
      check tracerInt.value == 1
      tracerInt.withValue(2):
        check tracerInt.value == 2
        tracerInt.withValue(3):
          check tracerInt.value == 3
        check tracerInt.value == 2
      check tracerInt.value == 1
    check tracerInt.value == 0

  test "exception in body reverts binding":
    expect ValueError:
      tracerInt.withValue(99):
        check tracerInt.value == 99
        raise newException(ValueError, "boom")
    check tracerInt.value == 0

  test "sequential repeated binding of the same var":
    # Re-entrant binding after a full unwind (distinct from nested/LIFO).
    tracerInt.withValue(1):
      check tracerInt.value == 1
    check tracerInt.value == 0
    tracerInt.withValue(2):
      check tracerInt.value == 2
    check tracerInt.value == 0
    tracerInt.withValue(3):
      check tracerInt.value == 3
    check tracerInt.value == 0

  test "different types bind independently":
    tracerInt.withValue(7):
      tracerStr.withValue("hello"):
        check tracerInt.value == 7
        check tracerStr.value == "hello"
      check tracerInt.value == 7
      check tracerStr.value == "default"
    check tracerInt.value == 0
    check tracerStr.value == "default"

  test "non-starred (module-private) key is readable/bindable in its own module":
    privateOnlyVar.withValue(5):
      check privateOnlyVar.value == 5
    check privateOnlyVar.value == 0

  test "mixed declarations — starred and non-starred keys both work":
    mixedPublic.withValue(11):
      mixedPrivate.withValue(22):
        check mixedPublic.value == 11
        check mixedPrivate.value == 22
      check mixedPublic.value == 11
      check mixedPrivate.value == 20
    check mixedPublic.value == 10

  test "currentContext snapshot used after binder exit returns correct value":
    # A snapshot captured inside a binder must remain valid after the
    # binder unwinds — the chain node must own its value, not point at
    # a since-popped stack frame.
    proc capture(): AsyncContext =
      tracerStr.withValue("hello from a long-gone stack frame"):
        result = currentContext()

    # Overwrite the freed stack slot so a use-after-free read would
    # return garbage rather than the original value.
    proc clobber() =
      var buf: array[2048, byte]
      for i in 0 ..< 2048: buf[i] = 0xAB.byte
      doAssert buf[0] == 0xAB.byte  # prevent dead-code elimination

    let snapshot = capture()
    clobber()
    withContext(snapshot):
      check tracerStr.value == "hello from a long-gone stack frame"

# --- Key construction and registry -------------------------------------------

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
  ## Deterministic rendering for the "ref-with-$" fixture below.

suite "contextvars (raw key): key construction and registry":

  test "defaulted key stores name, hasDefault, and registers":
    let k = newContextVar("t1Key", 42, private = false)
    check k.name == "t1Key"
    check k.hasDefault == true
    # Registration is observable only through dumpContext — the
    # registry-walking primitive itself is not on the public surface
    # (see testcontextvarssurface.nim).
    check dumpContext(currentContext()).anyIt(it.name == "t1Key")

  test "private key does not appear in dumpContext":
    let k = newContextVar("t2Key", 42, private = true)
    check k.private == true
    check not dumpContext(currentContext()).anyIt(it.name == "t2Key")

  test "must-bind arity has hasDefault false":
    let k = newContextVar[int]("t3Key")
    check k.hasDefault == false

  test "dumpContext renders defaults and bound values across T shapes":
    let intKey = newContextVar("t4Int", 7, private = false)
    let widgetKey = newContextVar[RenderWidget]("t4Widget", nil, private = false)
    let blobKey = newContextVar("t4Blob", RenderBlob(3), private = false)

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

# --- Keys as values: generic parameters, seq, Table --------------------------
# Capabilities an identifier-family design structurally could not offer,
# since there was never a runtime value to pass around. See
# docs/src/contextvars.md, "Keys as values".

suite "contextvars (raw key): keys as values":

  test "keys stored in a seq dispatch independently when read back":
    var keys = newSeq[ContextVar[int]]()
    for i in 0 ..< 4:
      keys.add newContextVar("collKey" & $i, 0)
    keys[2].withValue(99):
      check keys[2].value == 99
      check keys[0].value == 0
      check keys[1].value == 0
      check keys[3].value == 0

  test "keys work as a Table value, looked up and compared by ref identity":
    # `ContextVar[T]` has no `hash` of its own (only `AsyncContext` does
    # — see docs/src/contextvars.md, "Implementation"), so a key is a
    # Table *value*, not a hashable Table *key*, without a caller-
    # supplied hash. `==` alone (ref identity) is enough here.
    let a = newContextVar("tblKeyA", 1)
    let b = newContextVar("tblKeyB", 2)
    var t = initTable[string, ContextVar[int]]()
    t["a"] = a
    t["b"] = b
    check t["a"] == a
    check t["b"] == b
    check a != b

  test "a proc generic over the key itself dispatches without macro expansion":
    proc readOrDefault[T](cv: ContextVar[T]): T = cv.value
    let k = newContextVar("genericParamKey", 42)
    check readOrDefault(k) == 42
    k.withValue(7):
      check readOrDefault(k) == 7

# --- Ambient value and withValue ---------------------------------------------

suite "contextvars (raw key): ambient value and withValue":

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

# --- Binder contract + chain-state invariants --------------------------------
# Verifies every `withValue` binder pushes exactly one chain node and
# pops it on every exit path, via chainLen() and the chainBalance
# counter. Both are debug-only (when defined(chronosDebug)); the test
# build defines it.

let probeInt {.contextVar.} = 0

suite "contextvars: binder contract":

  when defined(chronosDebug):

    test "binder pushes exactly one node and pops on normal exit":
      let baseline = chainLen()
      probeInt.withValue(7):
        check chainLen() == baseline + 1
        check probeInt.value == 7
      check chainLen() == baseline

    test "binder pops on exception":
      let baseline = chainLen()
      try:
        probeInt.withValue(9):
          check chainLen() == baseline + 1
          raise newException(ValueError, "boom")
      except ValueError:
        discard
      check chainLen() == baseline

    test "nested binders nest cleanly":
      let baseline = chainLen()
      probeInt.withValue(1):
        check chainLen() == baseline + 1
        probeInt.withValue(2):
          check chainLen() == baseline + 2
          probeInt.withValue(3):
            check chainLen() == baseline + 3
          check chainLen() == baseline + 2
        check chainLen() == baseline + 1
      check chainLen() == baseline

    test "binder balance counter zeroes after every binder":
      let baseline = chainBalance
      probeInt.withValue(1):
        check chainBalance == baseline + 1
      check chainBalance == baseline
      probeInt.withValue(2):
        probeInt.withValue(3):
          check chainBalance == baseline + 2
      check chainBalance == baseline

# --- AsyncContext identity (==) ----------------------------------------------

let identA {.contextVar.} = 0

suite "contextvars: AsyncContext identity (==)":

  test "two captures with no intervening binding change are equal":
    let a = currentContext()
    let b = currentContext()
    check a == b

  test "capture inside a new binder is unequal to an outer capture":
    let outer = currentContext()
    identA.withValue(1):
      let inner = currentContext()
      check not (inner == outer)

  test "capture after restore is equal to the pre-binder capture":
    let before = currentContext()
    identA.withValue(1):
      discard currentContext()
    let after = currentContext()
    check after == before

  test "nested binder captures are pairwise unequal; restore re-equalizes":
    let c0 = currentContext()
    identA.withValue(1):
      let c1 = currentContext()
      check not (c1 == c0)
      identA.withValue(2):
        let c2 = currentContext()
        check not (c2 == c1)
        check not (c2 == c0)
      let c1Again = currentContext()
      check c1Again == c1
    let c0Again = currentContext()
    check c0Again == c0

  test "hash matches == identity: two equal snapshots hash equal":
    let a = currentContext()
    let b = currentContext()
    check a == b
    check hash(a) == hash(b)

  test "AsyncContext works as a Table key":
    var t: Table[AsyncContext, int]
    let outer = currentContext()
    t[outer] = 1
    identA.withValue(1):
      let inner = currentContext()
      t[inner] = 2
      check t[outer] == 1
      check t[inner] == 2
    check t[currentContext()] == 1

# --- Snapshot AsyncContext and [] --------------------------------------------

let snapOuter {.contextVar.} = 0

suite "contextvars (raw key): snapshot AsyncContext and []":

  test "snapshot sees the bound value without needing to be installed":
    snapOuter.withValue(11):
      let snap = currentContext()
      check snap[snapOuter] == 11

  test "snapshot outlives the binder that captured it; ambient reverts, snapshot doesn't":
    var snap: AsyncContext
    snapOuter.withValue(22):
      snap = currentContext()
    # The ambient reader has reverted, but the snapshot still walks its
    # own captured chain rather than the (now-reverted) ambient one.
    check snapOuter.value == 0
    check snap[snapOuter] == 22

  test "snapshot of an outer context read while an inner binding is ambient returns the OUTER value":
    snapOuter.withValue(1):
      let outerSnap = currentContext()
      snapOuter.withValue(2):
        check snapOuter.value == 2             # ambient sees the innermost binder
        check outerSnap[snapOuter] == 1         # snapshot still sees the outer value
      check snapOuter.value == 1

  test "defaulted-unbound snapshot returns the default":
    check currentContext()[snapOuter] == 0

  test "currentContext() captured inside withValue outlives the binder (raw key)":
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

# --- Must-bind (default-less) keys -------------------------------------------

var mustBindVar {.contextVar.}: int    # must-bind: no `= default`

suite "contextvars: must-bind (default-less) keys":

  test "reading unbound raises UnboundContextVarDefect":
    expect UnboundContextVarDefect:
      discard mustBindVar.value

  test "UnboundContextVarDefect carries the key's name":
    try:
      discard mustBindVar.value
      check false
    except UnboundContextVarDefect as e:
      check e.varName == "mustBindVar"

  test "snapshot reader's UnboundContextVarDefect also carries the key's name":
    let snap = currentContext()
    try:
      discard snap[mustBindVar]
      check false
    except UnboundContextVarDefect as e:
      check e.varName == "mustBindVar"

  test "reading bound works":
    mustBindVar.withValue(5):
      check mustBindVar.value == 5

  test "binding reverts on block exit; unbound read raises again":
    mustBindVar.withValue(5):
      discard
    expect UnboundContextVarDefect:
      discard mustBindVar.value

  test "nested must-bind rebinding restores LIFO, same as a defaulted key":
    mustBindVar.withValue(1):
      check mustBindVar.value == 1
      mustBindVar.withValue(2):
        check mustBindVar.value == 2
      check mustBindVar.value == 1

  test "snapshot reader raises on an unbound snapshot":
    let snap = currentContext()   # nothing bound anywhere for mustBindVar
    expect UnboundContextVarDefect:
      discard snap[mustBindVar]

  test "snapshot reader returns the bound value when bound in the snapshot":
    mustBindVar.withValue(9):
      let snap = currentContext()
      check snap[mustBindVar] == 9

suite "contextvars (raw key): must-bind Defect parity":

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

# --- dumpContext / $ ----------------------------------------------------------

type NoDollarPtr = ptr int
  ## Has no `$`: unlike an `object` (which gets one for free from
  ## `std/objectdollar`), a bare pointer type has no such fallback.

static:
  doAssert not compiles((block:
    var chronosProbeVal: NoDollarPtr
    $chronosProbeVal)),
    "control: NoDollarPtr must genuinely have no `$`, or the " &
    "placeholder-path test below is vacuous"

type DerefDollarRef = ref object
  ## `$` dereferences `field` — calling it on a nil value would crash,
  ## which is exactly what the nil-safe render path must avoid.
  field: int

proc `$`(r: DerefDollarRef): string = "field=" & $r.field

# Starred: dumpContext only ever sees a starred key's state — these
# fixtures test dumpContext itself, so they must be visible to it.
let dumpDefaulted* {.contextVar.} = 7
var dumpMustBind* {.contextVar.}: string      # must-bind
let dumpNoDollar* {.contextVar.}: NoDollarPtr = nil
let dumpRefNilDefault* {.contextVar.}: DerefDollarRef = nil

suite "contextvars: dumpContext and $":

  test "unbound defaulted key: bound=false, value is the rendered default":
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "dumpDefaulted":
        found = true
        check e.bound == false
        check e.value == "7"
    check found

  test "bound defaulted key: bound=true, value is the bound value":
    dumpDefaulted.withValue(99):
      let entries = dumpContext(currentContext())
      var found = false
      for e in entries:
        if e.name == "dumpDefaulted":
          found = true
          check e.bound == true
          check e.value == "99"
      check found

  test "unbound must-bind key: bound=false, placeholder value, dumpContext does not raise":
    # dumpContext must complete normally even though dumpMustBind.value
    # itself would raise UnboundContextVarDefect here.
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "dumpMustBind":
        found = true
        check e.bound == false
        check e.value == "<unbound>"
    check found

  test "bound must-bind key: bound=true, value is the bound value":
    dumpMustBind.withValue("hello"):
      let entries = dumpContext(currentContext())
      var found = false
      for e in entries:
        if e.name == "dumpMustBind":
          found = true
          check e.bound == true
          check e.value == "hello"
      check found

  test "a type with no `$` renders as the <no-$> placeholder":
    # The generic render hook has no per-T type-name string to splice
    # in (unlike the old macro's per-arm renderer proc, which captured
    # the type expression's `repr` at macro-expansion time) — a fixed
    # placeholder replaces the old `<TypeName>` form. See t4/t25 above.
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "dumpNoDollar":
        found = true
        check e.bound == false
        check e.value == "<no-$>"
    check found

  test "`$`(ctx) renders {name: value, ...} via the same machinery as dumpContext":
    dumpDefaulted.withValue(55):
      let s = $currentContext()
      check "dumpDefaulted: 55" in s

  test "ref-typed key with nil value renders as \"nil\" without calling $ (would crash otherwise)":
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "dumpRefNilDefault":
        found = true
        check e.bound == false
        check e.value == "nil"
    check found

  test "bound ref-typed key with a non-nil value renders via $":
    dumpRefNilDefault.withValue(DerefDollarRef(field: 42)):
      let entries = dumpContext(currentContext())
      var found = false
      for e in entries:
        if e.name == "dumpRefNilDefault":
          found = true
          check e.bound == true
          check e.value == "field=42"
      check found

  test "entries are sorted by name":
    let entries = dumpContext(currentContext())
    var names: seq[string]
    for e in entries: names.add e.name
    check names == sorted(names)

suite "contextvars (raw key): dumpContext and $":

  test "dumpContext on empty context: defaulted, must-bind, private semantics":
    let defaultedKey = newContextVar("t22Defaulted", 5, private = false)
    let mustBindKey = newContextVar[int]("t22MustBind", private = false)
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
    let k = newContextVar("t23Key", 1, private = false)
    var boundEntry: ContextVarEntry
    k.withValue(77):
      boundEntry = dumpContext(currentContext()).filterIt(it.name == "t23Key")[0]
    check boundEntry.bound == true
    check boundEntry.value == "77"

    let freshEntry = dumpContext(currentContext()).filterIt(it.name == "t23Key")[0]
    check freshEntry.bound == false
    check freshEntry.value == "1"

  test "`$` format parity and sorted order":
    let zKey = newContextVar("t24Zeta", 1, private = false)
    let aKey = newContextVar("t24Alpha", 2, private = false)
    let mKey = newContextVar("t24Mid", 3, private = false)
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
    let refKey = newContextVar[RenderWidget]("t25Ref", RenderWidget(id: 3), private = false)
    let nilKey = newContextVar[RenderWidget]("t25Nil", nil, private = false)
    let blobKey = newContextVar("t25Blob", RenderBlob(4), private = false)
    let intKey = newContextVar("t25Int", 8, private = false)

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

# --- Empty (default/nil) AsyncContext ----------------------------------------

let emptyCtxDefaulted {.contextVar.} = 3
var emptyCtxMustBind {.contextVar.}: int    # must-bind

suite "contextvars: empty (default/nil) AsyncContext":

  test "withContext over a default AsyncContext installs no bindings":
    var emptyCtx: AsyncContext   # zero value: no capture was ever taken
    withContext(emptyCtx):
      check emptyCtxDefaulted.value == 3      # defaulted key reads its default
      expect UnboundContextVarDefect:
        discard emptyCtxMustBind.value        # must-bind key raises

# --- {.contextVar.} declaration sugar ----------------------------------------

let t27Key* {.contextVar.} = 5

let t28Hidden {.contextVar.} = "hidden"
  ## No star -> private = true. Absence from `dumpContext` is what the
  ## test checks; the symbol itself stays reachable within this module
  ## (unlike cross-module unreachability, which
  ## tests/testcontextvarsexport.nim covers).

var t29MustBind* {.contextVar.}: string

let t30WidgetVar* {.contextVar.}: RenderWidget = nil

template t32Wrapper(nm: untyped; body: untyped): untyped =
  ## Forwards to the sugar macro from inside another template, so the
  ## identifier arrives as whatever node kind the wrapper's own
  ## parameter resolves to (probing the nnkIdent/nnkSym duality
  ## `splitContextVarNameAndPrivate` handles) — the successor to the
  ## old macro's `declareViaMacro`/`declareViaSym` arm-name probes,
  ## which tested the same nnkIdent/nnkSym duality for the statement
  ## macro this pragma replaced.
  let nm* {.contextVar.} = body

t32Wrapper(t32Wrapped, 777)

suite "contextvars (raw key): {.contextVar.} declaration sugar":

  test "starred let, T inferred: name, registration, and value":
    check t27Key.name == "t27Key"
    check t27Key.value == 5
    check dumpContext(currentContext()).anyIt(it.name == "t27Key")

  test "unstarred: private, absent from dumpContext":
    check t28Hidden.name == "t28Hidden"
    check t28Hidden.private == true
    check not dumpContext(currentContext()).anyIt(it.name == "t28Hidden")

  test "must-bind var form: unbound read raises with varName":
    check t29MustBind.hasDefault == false
    try:
      discard t29MustBind.value
      check false
    except UnboundContextVarDefect as e:
      check e.varName == "t29MustBind"
    t29MustBind.withValue("bound"):
      check t29MustBind.value == "bound"

  test "explicit-T-with-nil-default ref form":
    check t30WidgetVar.name == "t30WidgetVar"
    check t30WidgetVar.value == nil
    check dumpContext(currentContext()).filterIt(it.name == "t30WidgetVar")[0].value == "nil"

  test "one-symbol emission: no derived identifiers":
    check declared(t27Key)
    check not declared(withT27Key)
    check not declared(T27KeySlot)
    check not declared(t27KeyContextVarReg)
    check not declared(t27KeyContextVarRender)

  test "wrapper-template composition: sugar invoked through a forwarding template":
    check t32Wrapped.name == "t32Wrapped"
    check t32Wrapped.value == 777

# --- chronosDebug construction lock ------------------------------------------
# MUST stay last in this file: one-way for the process's lifetime, by
# design (mirrors real thread creation) — see chronos/contextvars.nim.
# This is also why this file must be the LAST contextvars test file
# testall.nim imports: every other contextvars test file constructs
# keys at runtime and must run before this suite locks construction.

when defined(chronosDebug):
  suite "contextvars (raw key): chronosDebug construction lock":

    test "newContextVar after lockContextVarConstruction() asserts":
      lockContextVarConstruction()
      expect AssertionDefect:
        discard newContextVar("t26AfterLock", 1)
