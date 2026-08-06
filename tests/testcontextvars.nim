#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Behavior tests for chronos's continuation-local storage primitive.
## See docs at chronos/contextvars.nim and docs/src/contextvars.md.

import std/macros
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
