#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Public-surface guardrail for continuation-local storage.
##
## Verifies that `import chronos` plus `import chronos/contextvars`
## expose only the intended public API — no dispatcher-internal
## primitives. Kept separate from testcontextvarsguardrails.nim, which
## imports internals directly and would make declared() checks vacuous.

import unittest2
import ../chronos
import ../chronos/contextvars
  # Looks unused to the compiler (declared() doesn't mark usage) but is
  # load-bearing for every assert below.

{.used.}

# --- Required public surface -------------------------------------------------

static:
  doAssert declared(contextVar),     "contextVar macro must be public"
  doAssert declared(AsyncContext),   "AsyncContext type must be public"
  doAssert declared(currentContext), "currentContext proc must be public"
  doAssert declared(withContext),    "withContext template must be public"
  doAssert declared(`==`),
    "`==`(AsyncContext, AsyncContext) must be public (declared() only " &
    "confirms the identifier resolves; the arity/type-specific probe " &
    "below confirms the actual overload)"
  doAssert compiles(currentContext() == currentContext()),
    "`==`(a, b: AsyncContext): bool must be public and callable"
  doAssert declared(dumpContext),      "dumpContext proc must be public"
  doAssert declared(ContextVarEntry),  "ContextVarEntry type must be public"
  doAssert declared(UnboundContextVarDefect),
    "UnboundContextVarDefect must be public — it's the type a caller " &
    "needs to name to catch an unbound must-bind read"
  doAssert compiles($(currentContext())),
    "`$`(ctx: AsyncContext): string must be public and callable"
  doAssert UnboundContextVarDefect is Defect,
    "UnboundContextVarDefect must be a Defect (not a CatchableError) " &
    "— see docs/src/contextvars.md, 'Required variables'"

# A must-bind arm (`var name: T`, no `= default`) must be legal syntax;
# this probe (module-scope, so it runs regardless of which test below
# executes) pins that the surface accepts it.
contextVar:
  var surfaceMustBind*: int

# --- Deliberately absent surface ---------------------------------------------
#
# An imperative token API (setName/reset) is deliberately not part of
# the frozen surface — withName and withContext/currentContext cover
# every known need. (`reset` itself can't be negatively asserted here:
# system.reset makes declared(reset) true in every module.)
when declared(AsyncContextToken):
  {.error: "`AsyncContextToken` must not be public: the imperative " &
           "token API was deliberately dropped from the frozen surface. " &
           "See the comment above this check.".}

# --- Anti-leak: dispatcher internals must not be reachable -------------------
#
# ContextNodeBase must stay unnameable here; the chain's actual
# immutability guarantee is the privacy of its `next` field (see the
# subtype probe below — unnameability alone wouldn't stop a
# macro-emitted slot subtype from reaching an inherited public field).
when declared(ContextNodeBase):
  {.error: "`ContextNodeBase` must not be reachable via `import chronos` " &
           "or `import chronos/contextvars`. See docs/src/contextvars.md, " &
           "'Capture discipline'.".}

when declared(nextNode):
  {.error: "`nextNode` (chain traversal getter) must not leak through " &
           "the public API — it lives in chronos/internal/contextnode.nim " &
           "for the slot walkers only.".}

when declared(linkNode):
  {.error: "`linkNode` (chain link writer) must not leak through the " &
           "public API — a reachable link primitive would reopen chain " &
           "mutation from user code.".}

# The strongest form of the cycle attack never names ContextNodeBase at
# all: a `contextVar` arm emits a nameable `ref object of
# ContextNodeBase` subtype, which inherits `next`. Probe it through the
# public path exactly as an attacker would.
contextVar:
  var surfaceProbe*: int = 0

static:
  doAssert compiles(SurfaceProbeSlot(value: 1)),
    "control: this module declared the arm, so constructing its slot " &
    "must compile here — otherwise the probes below are vacuous"
  doAssert not compiles((var s = SurfaceProbeSlot(value: 1); s.next = s)),
    "the inherited `next` field must not be writable through a " &
    "macro-emitted slot subtype — a public field here reopens the " &
    "cycle/chain-rewrite attack without naming ContextNodeBase."
  doAssert not compiles((var s = SurfaceProbeSlot(value: 1);
                         discard s.next)),
    "the inherited `next` field must not be readable through a slot " &
    "subtype either — traversal is internal-only."

when declared(currentAsyncContext):
  {.error: "`currentAsyncContext` threadvar must not leak through the " &
           "public API. Users must use `withContext` only.".}

when declared(contextLookup):
  {.error: "`contextLookup` must not leak through the public API. It is " &
           "invoked by macro-generated templates only.".}

when declared(contextBindSlot):
  {.error: "`contextBindSlot` must not leak through the public API.".}

when declared(contextLookupSnapshot):
  {.error: "`contextLookupSnapshot` must not leak through the public " &
           "API. It is invoked by macro-generated snapshot readers " &
           "(`name(ctx: AsyncContext)`) only.".}

when declared(contextFind):
  {.error: "`contextFind` must not leak through the public API. It is " &
           "invoked by macro-generated must-bind readers only.".}

when declared(contextFindSnapshot):
  {.error: "`contextFindSnapshot` must not leak through the public " &
           "API. It is invoked by macro-generated must-bind snapshot " &
           "readers and by dumpContext's per-arm render procs only.".}

when declared(ContextVarRenderProc):
  {.error: "`ContextVarRenderProc` must not leak through the public " &
           "API — it's the registry's internal render-proc type, " &
           "reached only via `dumpContext`.".}

when declared(ContextVarRegistration):
  {.error: "`ContextVarRegistration` must not leak through the public " &
           "API — the introspection registry's node type is internal; " &
           "`dumpContext`/`ContextVarEntry` are the public surface " &
           "over it.".}

when declared(registerContextVar):
  {.error: "`registerContextVar` must not leak through the public " &
           "API. It is invoked by macro-generated per-arm module init " &
           "statements only — a reachable registration primitive would " &
           "let user code inject fabricated entries into dumpContext.".}

when declared(contextVarRegistry):
  {.error: "`contextVarRegistry` (the registry-walking iterator) must " &
           "not leak through the public API. It is invoked by " &
           "`dumpContext` only.".}

when declared(capturingCallback):
  {.error: "`capturingCallback` must not leak through the public API. It lives " &
           "in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
           "`export futures`, and is used by dispatcher code only.".}

when declared(bareCallback):
  {.error: "`bareCallback` must not leak through the public API.".}

when declared(contextCallback):
  {.error: "`contextCallback` must not leak through the public API. It " &
           "lives in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
           "`export futures`, and is used by Windows IOCP completion " &
           "dispatch (`poll()`) only.".}

when declared(newCancelCallback):
  {.error: "`newCancelCallback` must not leak through the public API. It " &
           "lives in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
           "`export futures`, and is used by `cancelCallback=` only — " &
           "otherwise plain `import chronos` code could manufacture an " &
           "`InternalCancelCallback` and assign it directly to " &
           "`internalCancelcb`, bypassing `cancelCallback=`'s discipline.".}

when declared(withRestoredContext):
  {.error: "`withRestoredContext` must not leak through the public API. " &
           "It lives in chronos/futures.nim (placed there because " &
           "`asyncengine.nim` cannot name `ContextNodeBase` for its " &
           "typed parameter), excluded from `asyncengine.nim`'s `export " &
           "futures`, and is used by the dispatcher's fire sites only.".}

when declared(pinContext):
  {.error: "`pinContext` must not leak through the public API. It lives " &
           "in chronos/futures.nim beside `withRestoredContext`, excluded " &
           "from `asyncengine.nim`'s `export futures`, and is used by " &
           "continuation-pump resume guards only.".}

when declared(captureContextInto):
  {.error: "`captureContextInto` must not leak through the public API. " &
           "It lives in chronos/futures.nim (the shared " &
           "construction-discipline template), excluded from " &
           "`asyncengine.nim`'s `export futures`, and is used by " &
           "`capturingCallback`/`newCancelCallback` only — a reachable capture " &
           "primitive would let plain `import chronos` code write " &
           "`currentAsyncContext` into arbitrary fields, bypassing the " &
           "construction discipline entirely.".}

# --- Dispatcher queue fields and their backing type ---------------------------
#
# DispatcherBase.callbacks/idlers/ticks (backed by CallbackQueue) must
# stay private to chronos/internal/asyncengine.nim; only
# getThreadDispatcher() itself is public.

static:
  doAssert not compiles(getThreadDispatcher().callbacks),
    "`DispatcherBase.callbacks` must not be readable via `import chronos` " &
    "— it is private to chronos/internal/asyncengine.nim."
  doAssert not compiles(getThreadDispatcher().idlers),
    "`DispatcherBase.idlers` must not be readable via `import chronos` " &
    "— it is private to chronos/internal/asyncengine.nim."
  doAssert not compiles(getThreadDispatcher().ticks),
    "`DispatcherBase.ticks` must not be readable via `import chronos` " &
    "— it is private to chronos/internal/asyncengine.nim."

when declared(CallbackQueue):
  {.error: "`CallbackQueue` must not leak through the " &
           "public API. It backs the privatized `callbacks`/`idlers`/" &
           "`ticks` dispatcher fields and has no public-facing purpose " &
           "— unlike `std/deques.Deque` before it, which stayed exported " &
           "only because the fields it backed were themselves public.".}

# `context` is InternalAsyncCallback's (and InternalCancelCallback's)
# read-only getter, used by the dispatcher's fireWithContext/
# fireCancelCallback. Excluded from asyncengine.nim's `export futures`
# by name, which covers both overloads at once.
static:
  doAssert not compiles(default(AsyncCallback).context),
    "`context` getter must not leak through the public API. It lives " &
    "in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
    "`export futures`, and is used by the dispatcher's " &
    "`fireWithContext` only."
  doAssert not compiles(default(InternalCancelCallback).context),
    "`InternalCancelCallback`'s `context` getter must not leak through " &
    "the public API either — same exclusion, same reasoning, used by " &
    "the dispatcher's `fireCancelCallback` only."

# --- A trivial runtime assertion to keep the test file unittest-recognized ---

suite "contextvars: public surface":
  test "compile-time guardrails passed":
    # The static checks above are the real guardrails; this just
    # gives the runner a green dot.
    check true
