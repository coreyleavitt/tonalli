#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Behavior tests for chronos's continuation-local storage primitive.
## See docs at chronos/contextvars.nim and docs/src/contextvars.md.

import std/[algorithm, macros, strutils, tables]
import unittest2
import ../chronos/contextvars
import ../chronos/internal/contextvars_impl  # chainLen, chainBalance

{.used.}

# contextVar must accept arm names built as nnkIdent (this macro) or
# nnkSym (declareViaSym below) — the two AST shapes produced by macro
# composition.
macro declareViaMacro(): untyped =
  let nameSym = ident("composedInt")  # nnkIdent — baseline
  result = newCall(bindSym"contextVar",
    newStmtList(
      newTree(nnkVarSection,
        newTree(nnkIdentDefs, nameSym, ident"int", newLit(0)))))

declareViaMacro()

# genSym(nskVar) produces nnkSym — the macro must accept this form too.
macro declareViaSym(): untyped =
  let nameSym = genSym(nskVar, "symInt")  # nnkSym — hygiene path
  result = newCall(bindSym"contextVar",
    newStmtList(
      newTree(nnkVarSection,
        newTree(nnkIdentDefs, nameSym, ident"int", newLit(0)))))

declareViaSym()

contextVar:
  var tracerInt: int = 0
  var tracerStr: string = "default"
  # Casing edge cases:
  var x: int = 0              # single-char: name[1..^1] is empty string
  var User: string = ""       # already capitalized — `toUpperAscii` no-op

# No `*` marker — module-private; reader/binder must still work within
# this same module.
contextVar:
  var privateOnlyVar: int = 0

# Mixed block: starred and non-starred arms each honor their own marker.
contextVar:
  var mixedPublic*: int = 10
  var mixedPrivate: int = 20

suite "contextvars: declaration + scoped binding":

  test "scoped binding visible inside body":
    withTracerInt(42):
      check tracerInt() == 42

  test "default value when no binding in scope":
    check tracerInt() == 0

  test "binding reverts on normal block exit":
    withTracerInt(42):
      discard
    check tracerInt() == 0

  test "nested bindings see innermost; restore LIFO":
    withTracerInt(1):
      check tracerInt() == 1
      withTracerInt(2):
        check tracerInt() == 2
        withTracerInt(3):
          check tracerInt() == 3
        check tracerInt() == 2
      check tracerInt() == 1
    check tracerInt() == 0

  test "exception in body reverts binding":
    expect ValueError:
      withTracerInt(99):
        check tracerInt() == 99
        raise newException(ValueError, "boom")
    check tracerInt() == 0

  test "sequential repeated binding of the same var":
    # Re-entrant binding after a full unwind (distinct from nested/LIFO).
    withTracerInt(1):
      check tracerInt() == 1
    check tracerInt() == 0
    withTracerInt(2):
      check tracerInt() == 2
    check tracerInt() == 0
    withTracerInt(3):
      check tracerInt() == 3
    check tracerInt() == 0

  test "different types bind independently":
    withTracerInt(7):
      withTracerStr("hello"):
        check tracerInt() == 7
        check tracerStr() == "hello"
      check tracerInt() == 7
      check tracerStr() == "default"
    check tracerInt() == 0
    check tracerStr() == "default"

  test "contextVar accepts macro-constructed name (nnkIdent path)":
    # Baseline: macro-emitted contextVar with a bare-ident name works end-to-end.
    withComposedInt(11):
      check composedInt() == 11
    check composedInt() == 0

  test "contextVar handles single-character names":
    # Casing logic does toUpperAscii(name[0]) & name[1..^1]; single-char
    # names hit the edge case where name[1..^1] is empty.
    withX(123):
      check x() == 123
    check x() == 0

  test "contextVar handles already-capitalized names":
    # toUpperAscii on an already-uppercase letter is a no-op; verify the
    # macro doesn't double-capitalize (User -> UserSlot + withUser).
    withUser("alice"):
      check User() == "alice"
    check User() == ""

  test "contextVar accepts nnkSym name from macro composition":
    # Proves the macro tolerates an nnkSym arm name (from genSym).
    # Only the withSymInt binder is exercised — the reader isn't
    # guaranteed reachable here since gensyms don't leak out of the
    # producing macro by default.
    withSymInt(99):
      discard
    check true

  test "non-starred (module-private) var is readable/bindable in its own module":
    withPrivateOnlyVar(5):
      check privateOnlyVar() == 5
    check privateOnlyVar() == 0

  test "mixed block — starred and non-starred arms both work":
    withMixedPublic(11):
      withMixedPrivate(22):
        check mixedPublic() == 11
        check mixedPrivate() == 22
      check mixedPublic() == 11
      check mixedPrivate() == 20
    check mixedPublic() == 10

  test "currentContext snapshot used after binder exit returns correct value":
    # A snapshot captured inside a binder must remain valid after the
    # binder unwinds — the slot must own its value, not point at a
    # since-popped stack frame.
    proc capture(): AsyncContext =
      withTracerStr("hello from a long-gone stack frame"):
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
      check tracerStr() == "hello from a long-gone stack frame"

# --- Binder contract + chain-state invariants ------------------------------
# Verifies every `with*` binder pushes exactly one slot and pops it on
# every exit path, via chainLen() and the chainBalance counter. Both are
# debug-only (when defined(chronosDebug)); the test build defines it.

contextVar:
  var probeInt: int = 0

suite "contextvars: binder contract":

  when defined(chronosDebug):

    test "binder pushes exactly one slot and pops on normal exit":
      let baseline = chainLen()
      withProbeInt(7):
        check chainLen() == baseline + 1
        check probeInt() == 7
      check chainLen() == baseline

    test "binder pops on exception":
      let baseline = chainLen()
      try:
        withProbeInt(9):
          check chainLen() == baseline + 1
          raise newException(ValueError, "boom")
      except ValueError:
        discard
      check chainLen() == baseline

    test "nested binders nest cleanly":
      let baseline = chainLen()
      withProbeInt(1):
        check chainLen() == baseline + 1
        withProbeInt(2):
          check chainLen() == baseline + 2
          withProbeInt(3):
            check chainLen() == baseline + 3
          check chainLen() == baseline + 2
        check chainLen() == baseline + 1
      check chainLen() == baseline

    test "binder balance counter zeroes after every binder":
      let baseline = chainBalance
      withProbeInt(1):
        check chainBalance == baseline + 1
      check chainBalance == baseline
      withProbeInt(2):
        withProbeInt(3):
          check chainBalance == baseline + 2
      check chainBalance == baseline

# --- AsyncContext identity (==) ---------------------------------------------

contextVar:
  var identA: int = 0

suite "contextvars: AsyncContext identity (==)":

  test "two captures with no intervening binding change are equal":
    let a = currentContext()
    let b = currentContext()
    check a == b

  test "capture inside a new binder is unequal to an outer capture":
    let outer = currentContext()
    withIdentA(1):
      let inner = currentContext()
      check not (inner == outer)

  test "capture after restore is equal to the pre-binder capture":
    let before = currentContext()
    withIdentA(1):
      discard currentContext()
    let after = currentContext()
    check after == before

  test "nested binder captures are pairwise unequal; restore re-equalizes":
    let c0 = currentContext()
    withIdentA(1):
      let c1 = currentContext()
      check not (c1 == c0)
      withIdentA(2):
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
    withIdentA(1):
      let inner = currentContext()
      t[inner] = 2
      check t[outer] == 1
      check t[inner] == 2
    check t[currentContext()] == 1

# --- Per-variable snapshot readers ------------------------------------------

contextVar:
  var snapOuter: int = 0

suite "contextvars: snapshot readers":

  test "snapshot reader sees the bound value without needing to be installed":
    withSnapOuter(11):
      let snap = currentContext()
      check snapOuter(snap) == 11

  test "snapshot outlives the binder that captured it; ambient reverts, snapshot doesn't":
    var snap: AsyncContext
    withSnapOuter(22):
      snap = currentContext()
    # The ambient reader has reverted, but the snapshot still walks its
    # own captured chain rather than the (now-reverted) ambient one.
    check snapOuter() == 0
    check snapOuter(snap) == 22

  test "snapshot of an outer context read while an inner binding is ambient returns the OUTER value":
    withSnapOuter(1):
      let outerSnap = currentContext()
      withSnapOuter(2):
        check snapOuter() == 2             # ambient sees the innermost binder
        check snapOuter(outerSnap) == 1    # snapshot still sees the outer value
      check snapOuter() == 1

  test "defaulted-unbound snapshot returns the default":
    check snapOuter(currentContext()) == 0

# --- Must-bind (default-less) arms ------------------------------------------

contextVar:
  var mustBindVar: int    # must-bind: no `= default`

suite "contextvars: must-bind (default-less) arms":

  test "reading unbound raises UnboundContextVarDefect":
    expect UnboundContextVarDefect:
      discard mustBindVar()

  test "UnboundContextVarDefect carries the arm's name":
    try:
      discard mustBindVar()
      check false
    except UnboundContextVarDefect as e:
      check e.varName == "mustBindVar"

  test "snapshot reader's UnboundContextVarDefect also carries the arm's name":
    let snap = currentContext()
    try:
      discard mustBindVar(snap)
      check false
    except UnboundContextVarDefect as e:
      check e.varName == "mustBindVar"

  test "reading bound works":
    withMustBindVar(5):
      check mustBindVar() == 5

  test "binding reverts on block exit; unbound read raises again":
    withMustBindVar(5):
      discard
    expect UnboundContextVarDefect:
      discard mustBindVar()

  test "nested must-bind rebinding restores LIFO, same as a defaulted var":
    withMustBindVar(1):
      check mustBindVar() == 1
      withMustBindVar(2):
        check mustBindVar() == 2
      check mustBindVar() == 1

  test "snapshot reader raises on an unbound snapshot":
    let snap = currentContext()   # nothing bound anywhere for mustBindVar
    expect UnboundContextVarDefect:
      discard mustBindVar(snap)

  test "snapshot reader returns the bound value when bound in the snapshot":
    withMustBindVar(9):
      let snap = currentContext()
      check mustBindVar(snap) == 9

# --- dumpContext / $ --------------------------------------------------------

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

contextVar:
  # Starred: dumpContext only ever sees a starred arm's state — these
  # fixtures test dumpContext itself, so they must be visible to it.
  var dumpDefaulted*: int = 7
  var dumpMustBind*: string      # must-bind
  var dumpNoDollar*: NoDollarPtr = nil
  var dumpRefNilDefault*: DerefDollarRef = nil

suite "contextvars: dumpContext and $":

  test "unbound defaulted var: bound=false, value is the rendered default":
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "dumpDefaulted":
        found = true
        check e.bound == false
        check e.value == "7"
    check found

  test "bound defaulted var: bound=true, value is the bound value":
    withDumpDefaulted(99):
      let entries = dumpContext(currentContext())
      var found = false
      for e in entries:
        if e.name == "dumpDefaulted":
          found = true
          check e.bound == true
          check e.value == "99"
      check found

  test "unbound must-bind var: bound=false, placeholder value, dumpContext does not raise":
    # dumpContext must complete normally even though dumpMustBind()
    # itself would raise UnboundContextVarDefect here.
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "dumpMustBind":
        found = true
        check e.bound == false
        check e.value == "<unbound>"
    check found

  test "bound must-bind var: bound=true, value is the bound value":
    withDumpMustBind("hello"):
      let entries = dumpContext(currentContext())
      var found = false
      for e in entries:
        if e.name == "dumpMustBind":
          found = true
          check e.bound == true
          check e.value == "hello"
      check found

  test "a type with no `$` renders as a <TypeName> placeholder":
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "dumpNoDollar":
        found = true
        check e.bound == false
        check e.value == "<NoDollarPtr>"
    check found

  test "`$`(ctx) renders {name: value, ...} via the same machinery as dumpContext":
    withDumpDefaulted(55):
      let s = $currentContext()
      check "dumpDefaulted: 55" in s

  test "ref-typed arm with nil value renders as \"nil\" without calling $ (would crash otherwise)":
    let entries = dumpContext(currentContext())
    var found = false
    for e in entries:
      if e.name == "dumpRefNilDefault":
        found = true
        check e.bound == false
        check e.value == "nil"
    check found

  test "bound ref-typed arm with a non-nil value renders via $":
    withDumpRefNilDefault(DerefDollarRef(field: 42)):
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

# --- Empty (default/nil) AsyncContext ----------------------------------------

contextVar:
  var emptyCtxDefaulted: int = 3
  var emptyCtxMustBind: int    # must-bind

suite "contextvars: empty (default/nil) AsyncContext":

  test "withContext over a default AsyncContext installs no bindings":
    var emptyCtx: AsyncContext   # zero value: no capture was ever taken
    withContext(emptyCtx):
      check emptyCtxDefaulted() == 3      # defaulted arm reads its default
      expect UnboundContextVarDefect:
        discard emptyCtxMustBind()        # must-bind arm raises
