#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Drift-detection guardrails for the first-class `ContextVar[T]` key
## runtime (`chronos/internal/contextkeys.nim`). See
## .claude/rfc/0002-contextvars-firstclass-keys.handoff.md, "Rewrite
## inventory" (guardrail fates) and "Representation".
##
## Transitional file: pins the NEW guardrails the redesign requires;
## the still-macro-based tests/testcontextvarsguardrails.nim and
## tests/testcontextvarssurface.nim stay untouched until final
## assembly, where the two guardrail sets merge. Each check is a
## compile-time assertion (`static:` / `when compiles`) or, where the
## guardrail is semantic rather than structural, a runtime assertion —
## mirroring the old files' technique of asserting on the exact probe
## expression, with a control assertion first wherever a bare
## `not compiles` could otherwise be vacuous (e.g. a typo'd field name).
##
## t31 in tests/testcontextkeys.nim already covers one-symbol emission
## for the `{.contextVar.}` pragma; not duplicated here.

import std/[sequtils, tables]
import unittest2
import ../chronos/internal/contextkeys
import ../chronos
  # Brings `withTimeout` into scope for guardrail 9 below.

{.used.}

# --- Guardrail 1: ContextVar[T] is ref ---------------------------------------
#
# Ref identity IS key identity (see "Representation" in the handoff):
# aliases compare equal, keys work in Table/seq for free, and a
# default-initialized `nil` key is a detectable invalid state. A value
# `object` key was rejected for exactly this reason.

static:
  doAssert ContextVar[int] is ref,
    "ContextVar[T] must be a `ref object` — ref identity is key " &
    "identity; a value object would let a copy silently break it."
  doAssert ContextVarBase is ref,
    "ContextVarBase must be a `ref object` too — ContextVar[T] " &
    "inherits it, so the base carries the same identity guarantee."

# --- Guardrail 2: no public mutable fields -----------------------------------
#
# `name`/`hasDefault`/`private` are exposed as read-only accessor
# procs (same spelling as the old field names, so `cv.name` etc. still
# reads via UFCS); `render`/`default`/the registry link
# (`nextRegistered`) are not reachable at all outside this module. A
# writable field here would let user code corrupt a key after
# construction — e.g. rewrite `render` to defeat `dumpContext`, or
# flip `hasDefault` to bypass `UnboundContextVarDefect`.

static:
  # Controls: reads must still compile, or the write probes below
  # would be vacuous (indistinguishable from a typo'd field name).
  doAssert compiles((let k = newContextVar("g2CtlName", 0); discard k.name)),
    "control: `.name` must be readable — if this fails, the write " &
    "probe below isn't probing what it claims to."
  doAssert compiles((let k = newContextVar("g2CtlHasDefault", 0); discard k.hasDefault)),
    "control: `.hasDefault` must be readable."
  doAssert compiles((let k = newContextVar("g2CtlPrivate", 0); discard k.private)),
    "control: `.private` must be readable."

  doAssert not compiles((let k = newContextVar("g2Name", 0); k.name = "evil")),
    "ContextVar[T].name must not be writable — it's a read-only " &
    "accessor over a private field (RFC round 1, pinned decisions)."
  doAssert not compiles((let k = newContextVar("g2HasDefault", 0); k.hasDefault = false)),
    "ContextVar[T].hasDefault must not be writable — flipping it " &
    "post-construction would desync a must-bind key from its Defect."
  doAssert not compiles((let k = newContextVar("g2Private", 0); k.private = true)),
    "ContextVar[T].private must not be writable — flipping it " &
    "post-construction wouldn't retroactively (un)register the key, " &
    "so a writable field would make `.private` lie about registration."
  doAssert not compiles((let k = newContextVar("g2Default", 0); k.default = 1)),
    "ContextVar[T].default must not be reachable at all outside this " &
    "module — it's on the RFC's public-surface Forbidden list."
  doAssert not compiles((let k = newContextVar("g2Render", 0); k.render = nil)),
    "ContextVarBase.render must not be reachable at all outside this " &
    "module — a writable render hook would let user code corrupt " &
    "dumpContext's output for a key it doesn't own."
  doAssert not compiles((let k = newContextVar("g2Registry", 0); k.nextRegistered = nil)),
    "ContextVarBase.nextRegistered (the intrusive registry link) must " &
    "not be reachable at all outside this module — a writable link " &
    "would let user code splice or unlink registry nodes."

# --- Guardrail 3: no custom `==` on ContextVar -------------------------------
#
# Chain-node dispatch (the `[]` walk) depends on ref-identity
# comparison; a value-based `==` would silently alias two distinct
# keys constructed with the same arguments.

type
  G3UnrelatedRef = ref object
    tag: int

static:
  doAssert not compiles(newContextVar("g3Unrelated", 0) == G3UnrelatedRef(tag: 1)),
    "ContextVar must not compare equal to an unrelated ref type — no " &
    "accidental converter or structural `==` should bridge the two " &
    "hierarchies."

suite "contextkeys guardrails: g3 no custom ==":
  test "two identically-constructed same-T keys compare unequal (ref identity)":
    let k1 = newContextVar("g3Key", 0)
    let k2 = newContextVar("g3Key", 0)
    check k1 != k2

# --- Guardrail 4: imperative set/reset stays absent --------------------------
#
# RFC 0001's binding is block-scoped only (`withValue`); no imperative
# token API. `reset`/`set` can't be probed via `declared()` the way an
# absent surface symbol normally would (`system.reset` makes
# `declared(reset)` true in every module — same caveat the old surface
# file notes), so the probe is call-shape instead: none of these
# verb-shaped calls with a value argument may resolve against
# `ContextVar[T]`.

static:
  doAssert not compiles((let k = newContextVar("g4Set", 0); k.set(1))),
    "ContextVar[T] must not have an imperative `set` — binding is " &
    "block-scoped only via `withValue` (RFC 0001, 'No imperative " &
    "token API')."
  doAssert not compiles((let k = newContextVar("g4Reset", 0); k.reset(1))),
    "ContextVar[T] must not have an imperative `reset` taking a value."
  doAssert not compiles((let k = newContextVar("g4Push", 0); k.push(1))),
    "ContextVar[T] must not have a `push`-shaped imperative call."
  doAssert not compiles((let k = newContextVar("g4Pop", 0); k.pop(1))),
    "ContextVar[T] must not have a `pop`-shaped imperative call."
  doAssert not compiles((let k = newContextVar("g4Free", 0); set(k, 1))),
    "free-function `set(cv, v)` must not resolve either — same probe, " &
    "non-UFCS call shape."

# --- Guardrail 5: chain-node construction and `next` access unreachable -----
#
# `ContextNode`/`ContextNodeKeyed` are both unexported: neither name
# resolves outside this module at all, so there is no `cast`-free way
# to construct a node or reach its `next`. (Finding fixed as part of
# this guardrail: `ContextNode[T]` was previously marked exported
# though nothing outside this module ever named it — `withValue`/`[]`
# build and walk nodes from their own definitions, which resolve
# against this module's scope regardless of the caller's, per Nim
# template/proc symbol binding; exporting it bought nothing but a
# reachable construction path. Unexporting it closes g5 more strongly
# than the minimum ask: the type itself is unnameable, not just its
# `next` field.) `ContextNodeBase.next` (the inherited field) stays
# private to contextnode.nim unchanged — that half of the guardrail
# was already true before this slice.

static:
  doAssert not compiles(ContextNode[int]),
    "ContextNode[T] must not be nameable outside chronos/internal/" &
    "contextkeys.nim — see the finding recorded above this block."
  doAssert not compiles(ContextNodeKeyed),
    "ContextNodeKeyed must not be nameable outside chronos/internal/" &
    "contextkeys.nim either."
  doAssert not compiles((var n: ContextNodeBase; n.next = n)),
    "ContextNodeBase.next must stay unwritable from outside " &
    "chronos/internal/contextnode.nim — unchanged by this slice, " &
    "reconfirmed here because it's the field the whole guardrail " &
    "protects."
  doAssert not compiles((var n: ContextNodeBase; discard n.next)),
    "ContextNodeBase.next must stay unreadable from outside " &
    "chronos/internal/contextnode.nim either."

# --- Guardrail 6: std/tables.withValue coexistence (pinned decision 1) ------
#
# Overloads dispatch on receiver type, ordinary stdlib verb-sharing à
# la `len`/`[]` — not a compile hazard. Compiles a module importing
# both std/tables and this module, calling both `withValue`s side by
# side, including once from inside a generic proc.

proc g6GenericRoundtrip[T](cv: ContextVar[T], v: T): T =
  cv.withValue(v):
    result = cv.value

suite "contextkeys guardrails: g6 std/tables.withValue coexistence":
  test "Table.withValue and ContextVar.withValue compile and behave side by side":
    let cv = newContextVar("g6Key", 0)
    var t = {"a": 1}.toTable

    t.withValue("a", v):
      v[] = 99

    cv.withValue(7):
      check cv.value == 7
      check t["a"] == 99

    check g6GenericRoundtrip(cv, 55) == 55

# --- Guardrail 7: name-string drift -------------------------------------------
#
# The raw constructor's `name` argument is the DRY wart the RFC
# accepts for non-sugar call sites (round 1, pinned decisions); this
# guardrail pins that the string surfaces verbatim, unmangled, on both
# consumers: dumpContext and UnboundContextVarDefect.varName.

suite "contextkeys guardrails: g7 name-string drift":
  test "raw-constructor name surfaces verbatim in dumpContext":
    let k = newContextVar("rawNamed", 0)
    let entries = dumpContext(currentContext()).filterIt(it.name == "rawNamed")
    check entries.len == 1

  test "raw-constructor name surfaces verbatim in UnboundContextVarDefect.varName":
    let k = newContextVar[int]("rawNamed")
    try:
      discard k.value
      check false
    except UnboundContextVarDefect as e:
      check e.varName == "rawNamed"

# --- Guardrail 8: same-name keys don't alias ----------------------------------
#
# Duplicate name strings are representable and accepted as
# cosmetic-only (matching PEP 567): dumpContext may show two entries
# with the same label. What's pinned instead is the semantic property —
# binding one same-name key is never observable through the other.

suite "contextkeys guardrails: g8 same-name keys don't alias":
  test "binding one of two same-name same-T keys leaves the other's default; both list in dumpContext":
    let a = newContextVar("g8Dup", 1)
    let b = newContextVar("g8Dup", 1)

    a.withValue(99):
      check a.value == 99
      check b.value == 1

    check a.value == 1
    check b.value == 1

    let entries = dumpContext(currentContext()).filterIt(it.name == "g8Dup")
    check entries.len == 2

# --- Guardrail 9: positive inverse of the old collision guardrail -----------
#
# The old macro's per-arm `withName` collided with an already-declared
# symbol of the same name (`timeout` vs. chronos's own `withTimeout`
# combinator) — a compile ERROR, guarded in the old
# testcontextvarsguardrails.nim. First-class keys mint no derived
# identifiers, so this bug class is unrepresentable: a key literally
# named "timeout" and chronos's `withTimeout` coexist without
# conflict. Proof is compile-and-run, not `not compiles`, since the
# claim is the ABSENCE of an error.

let timeout* {.contextVar.} = 5
  ## Deliberately named to match the RFC's example collision case —
  ## the old macro would have refused this declaration outright.

suite "contextkeys guardrails: g9 no collision with chronos's own symbols":
  test "a key literally named `timeout` coexists with chronos's withTimeout":
    check timeout.value == 5
    check declared(withTimeout)

# --- A trivial runtime assertion to keep the file unittest-recognized -------

suite "contextkeys guardrails: compile-time checks":
  test "compile-time guardrails passed":
    # The static checks above are the real guardrails; this just
    # gives the runner a green dot.
    check true
