#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Behavior tests for chronos's continuation-local storage primitive.
## See docs at chronos/contextvars.nim and docs/src/contextvars.md.

import std/[macros, strutils]
import unittest2
import ../chronos/contextvars
import ../chronos/internal/contextvars_impl  # chainLen, chainBalance

{.used.}

# Exercise contextVar's tolerance for arm names arriving as AST nodes
# other than a bare identifier — a prerequisite for composing
# contextVar from other macros. This macro builds the name via plain
# `ident` (nnkIdent); `declareViaSym` below builds it via
# `genSym(nskVar)` (nnkSym), the form that appears when composing
# macros at semantic-token boundaries.
macro declareViaMacro(): untyped =
  let nameSym = ident("composedInt")  # nnkIdent — baseline
  result = newCall(bindSym"contextVar",
    newStmtList(
      newTree(nnkVarSection,
        newTree(nnkIdentDefs, nameSym, ident"int", newLit(0)))))

declareViaMacro()

# nnkSym path: a macro constructs the name via `genSym(nskVar)`, which
# produces `nnkSym`. The contextVar macro must accept this form for
# advanced composition (matching the `eqIdent`/`isIdentLike` hygiene
# pattern common in macro-heavy downstream libraries).
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

# No `*` marker — module-private. Reader/binder must still work from
# within this same module (privacy only affects cross-module
# reachability; see testcontextvarsexport.nim for that side).
contextVar:
  var privateOnlyVar: int = 0

# Mixed block — starred and non-starred arms in the same `contextVar`
# block must each honor their own marker independently.
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
    # Bind X, exit, bind X again. Distinct from the nested-binding test
    # (which proves LIFO restore for overlapping binds) — this proves
    # that the binder is re-entrant cleanly after a full unwind.
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
    # Baseline: macro-emitted contextVar with bare-ident name works
    # end-to-end. Anchors the "composed from macro" usage pattern.
    withComposedInt(11):
      check composedInt() == 11
    check composedInt() == 0

  test "contextVar handles single-character names":
    # The casing logic does `toUpperAscii(name[0]) & name[1 .. ^1]`.
    # Single-char names hit the edge case where `name[1 .. ^1]` is
    # empty. Verify the resulting `withX` binder still works.
    withX(123):
      check x() == 123
    check x() == 0

  test "contextVar handles already-capitalized names":
    # `toUpperAscii` of an already-uppercase letter is a no-op.
    # `User` -> `UserSlot` + `withUser`. Verify nothing collides
    # (e.g., the macro doesn't double-capitalize).
    withUser("alice"):
      check User() == "alice"
    check User() == ""

  test "contextVar accepts nnkSym name from macro composition":
    # `declareViaSym` constructs the arm name via `genSym(nskVar)`,
    # which produces `nnkSym`. This test proves the macro tolerates
    # the gensym path — required for advanced macro composition
    # (matches the `eqIdent`/`isIdentLike` hygiene pattern).
    #
    # `$genSym(nskVar, "symInt")` returns the base name "symInt", so
    # the emitted slot type / reader / binder all get valid Nim
    # identifier names. Whether the reader template is reachable from
    # this test scope depends on gensym scoping rules — and gensyms
    # don't leak out of the producing macro by default. We don't rely
    # on the reader here; only the `withSymInt` binder (which is
    # constructed via `ident("with"&name)`, always a fresh exportable
    # identifier) is exercised. This test proves the macro accepts
    # the nnkSym AST shape at all; end-to-end machinery is covered
    # by the nnkIdent baseline above.
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
    # Architectural soundness invariant: a snapshot captured inside
    # `withName(v): body` must remain usable after `body` exits and
    # the binder unwinds. A slot that stored a pointer to a
    # stack-local `v` instead of owning it inline would fail this —
    # the snapshot would hold a node whose value pointer targets the
    # now-popped stack frame of the `withName` expansion, so reading
    # through the snapshot would dereference freed memory.
    proc capture(): AsyncContext =
      withTracerStr("hello from a long-gone stack frame"):
        result = currentContext()
      # binder exits — pointer-to-stack-local now dangles

    # Force the freed stack slot to be reused with different bytes,
    # so a UAF read returns garbage rather than the original value.
    proc clobber() =
      var buf: array[2048, byte]
      for i in 0 ..< 2048: buf[i] = 0xAB.byte
      # `buf` lives in the same frame range that `capture`'s local
      # occupied; if the implementation stored `addr` of that local,
      # the snapshot now points into this buffer.
      doAssert buf[0] == 0xAB.byte  # prevent dead-code elimination

    let snapshot = capture()
    clobber()
    withContext(snapshot):
      check tracerStr() == "hello from a long-gone stack frame"

# --- Binder contract + chain-state invariants ------------------------------
#
# `AsyncCallback.context` is a native `ref ContextNodeBase`; Nim's MM
# refcounts the captured chain at every drop pattern. That property is
# a language guarantee, not a chronos invariant — we inherit it from
# the same mechanism that makes `seq[ref T]`, `Table[K, ref V]`, etc.
# work. We do NOT test it per-drop-pattern.
#
# What we DO test is the chronos-side binder contract: every `with*`
# binder pushes exactly one slot and pops it on every exit path. Two
# deterministic, MM-portable mechanisms:
#
# 1. `chainLen()` — direct inspection of `currentAsyncContext`.
#    After a balanced binder pair the chain depth must return to
#    baseline.
# 2. `chainBalance` — threadvar counter `inc`'d at slot push,
#    `dec`'d at slot pop. Nonzero at suite end signals an unbalanced
#    binder. Checked in `testutils.nim` alongside `pendingFuturesCount`.
#
# Both are pure sync — no dispatcher needed — so they live here in
# `testcontextvars.nim` rather than in `testcontextvarsasync.nim`.
# Both are debug-only (`when defined(chronosDebug)` in
# `contextvars_impl.nim`); the chronos test build sets `-d:chronosDebug`,
# so the tests are observable in CI.

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
    # Outside the binder: the ambient reader has reverted to the
    # default, but the snapshot still remembers the binder's value —
    # proving the snapshot reader walks `snap`'s own chain, not the
    # (now-reverted) ambient one.
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
  ## Deliberately has no `$`: a plain `object` picks one up for free
  ## from `std/objectdollar`'s generic field-by-field renderer, which
  ## would not exercise dumpContext's placeholder path. A bare pointer
  ## type has no such fallback.

static:
  doAssert not compiles((block:
    var chronosProbeVal: NoDollarPtr
    $chronosProbeVal)),
    "control: NoDollarPtr must genuinely have no `$`, or the " &
    "placeholder-path test below is vacuous"

contextVar:
  var dumpDefaulted: int = 7
  var dumpMustBind: string      # must-bind
  var dumpNoDollar: NoDollarPtr = nil

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
    # Introspection is total: dumpContext must complete normally even
    # though `dumpMustBind()` itself would raise `UnboundContextVarDefect`
    # right now.
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
