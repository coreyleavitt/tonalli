## Public-surface guardrail for continuation-local storage.
##
## Verifies that `import chronos` plus `import chronos/contextvars` —
## the only two imports a user ever needs — expose ONLY the intended
## public API and none of the dispatcher-internal primitives.
##
## Kept in its own module rather than folded into
## `testcontextvarsguardrails.nim`: that file imports the internal
## modules directly (it needs them for white-box checks), which would
## make every `declared()` check below trivially true. This module
## imports ONLY the public paths so the checks mean what they say.
##
## See docs/src/contextvars.md §Capture discipline.

import unittest2
import ../chronos
import ../chronos/contextvars
  # Flagged "imported and not used" by the compiler because `declared()`
  # checks don't mark symbols as used — the import is load-bearing for
  # every positive assert below; removing it fails them all.

{.used.}

# --- Required public surface -------------------------------------------------

static:
  doAssert declared(contextVar),     "contextVar macro must be public"
  doAssert declared(AsyncContext),   "AsyncContext type must be public"
  doAssert declared(currentContext), "currentContext proc must be public"
  doAssert declared(withContext),    "withContext template must be public"

# --- Deliberately absent surface ---------------------------------------------
#
# An imperative token API (`setName(v): AsyncContextToken` per arm plus
# a shared `reset(token)`) is deliberately NOT part of the frozen
# surface: block-scoped `withName` covers binding within a single
# logical task, and `currentContext()`/`withContext()` covers
# independently-fired callbacks — no known shape needs a token. A token
# API also carries costs the two shipped primitives don't: a
# Defect-raising misuse surface (LIFO/reuse/never-bound guards), a
# value-type reuse-guard footgun under token copies, and a semantic
# collision with `system.reset` (which elsewhere in chronos means
# "zero this value"). Reintroduce only with a motivating example that
# `withName` genuinely cannot express. (`reset` itself cannot be
# negatively asserted here — `system.reset` makes `declared(reset)`
# true in every module.)
when declared(AsyncContextToken):
  {.error: "`AsyncContextToken` must not be public: the imperative " &
           "token API was deliberately dropped from the frozen surface. " &
           "See the comment above this check.".}

# --- Anti-leak: dispatcher internals must not be reachable -------------------
#
# `ContextNodeBase` is the base of the binding chain. Keeping it
# unnameable here blocks `distinct` -> base conversion of an
# `AsyncContext` snapshot; the chain's actual immutability guarantee is
# the PRIVACY of its `next` field (see contextnode.nim's module doc and
# the subtype probe below — unnameability alone would not stop a user's
# own macro-emitted slot subtype from reaching an inherited public
# field). `chronos/futures.nim` imports `ContextNodeBase` from
# `chronos/internal/contextnode.nim` but never exports it, so `export
# futures` (asyncengine -> asyncloop -> chronos) does not forward it.
when declared(ContextNodeBase):
  {.error: "`ContextNodeBase` must not be reachable via `import chronos` " &
           "or `import chronos/contextvars`. See docs/src/contextvars.md " &
           "§Capture discipline.".}

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

when declared(userCallback):
  {.error: "`userCallback` must not leak through the public API. It lives " &
           "in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
           "`export futures`, and is used by dispatcher code only.".}

when declared(internalCallback):
  {.error: "`internalCallback` must not leak through the public API.".}

when declared(newCancelCallback):
  {.error: "`newCancelCallback` must not leak through the public API. It " &
           "lives in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
           "`export futures`, and is used by `cancelCallback=` only — " &
           "otherwise plain `import chronos` code could manufacture an " &
           "`InternalCancelCallback` and assign it directly to " &
           "`internalCancelcb`, bypassing `cancelCallback=`'s discipline " &
           "(RFC 0001 D5).".}

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
           "It lives in chronos/futures.nim (RFC 0001 D8's shared " &
           "construction-discipline template), excluded from " &
           "`asyncengine.nim`'s `export futures`, and is used by " &
           "`userCallback`/`newCancelCallback` only — a reachable capture " &
           "primitive would let plain `import chronos` code write " &
           "`currentAsyncContext` into arbitrary fields, bypassing the " &
           "construction discipline entirely.".}

# --- RFC 0001 D9: dispatcher queue fields and their backing type -------------
#
# `DispatcherBase.callbacks`/`idlers`/`ticks` were privatized when their
# type swapped from `std/deques.Deque` to the move-based `CallbackQueue`
# (`chronos/internal/callbackqueue.nim`) — the type swap grazed all three
# fields either way, so D9 closes off external access at the same time
# (all touch sites live inside `chronos/internal/asyncengine.nim` and
# `chronos/internal/asyncfutures.nim`'s `callSoon`-routed call).
# `getThreadDispatcher()` (this module's only way to reach a live
# `PDispatcher`) stays public — only the three fields themselves and the
# queue type backing them are excluded.

static:
  doAssert not compiles(getThreadDispatcher().callbacks),
    "`DispatcherBase.callbacks` must not be readable via `import chronos` " &
    "— it is private to chronos/internal/asyncengine.nim (RFC 0001 D9)."
  doAssert not compiles(getThreadDispatcher().idlers),
    "`DispatcherBase.idlers` must not be readable via `import chronos` " &
    "— it is private to chronos/internal/asyncengine.nim (RFC 0001 D9)."
  doAssert not compiles(getThreadDispatcher().ticks),
    "`DispatcherBase.ticks` must not be readable via `import chronos` " &
    "— it is private to chronos/internal/asyncengine.nim (RFC 0001 D9)."

when declared(CallbackQueue):
  {.error: "`CallbackQueue` (RFC 0001 D9) must not leak through the " &
           "public API. It backs the privatized `callbacks`/`idlers`/" &
           "`ticks` dispatcher fields and has no public-facing purpose " &
           "— unlike `std/deques.Deque` before it, which stayed exported " &
           "only because the fields it backed were themselves public.".}

# `context` is `InternalAsyncCallback`'s (and, since RFC 0001 D5,
# `InternalCancelCallback`'s) read-only getter — both declared in
# `chronos/futures.nim`, used by the dispatcher's `fireWithContext` and
# `fireCancelCallback` respectively. It has no user-facing purpose: the
# value it returns is `ContextNodeBase`, which this file already
# establishes is unnameable here, so `.next` can't be written and the C1
# cycle attack stays closed even without this check — but the getter
# itself should still not be reachable via plain `import chronos`.
# Excluding the `context` identifier in `chronos/internal/asyncengine.
# nim`'s `export futures except ...` covers both overloads at once (the
# exclusion is by name, not by signature) — the second assertion below
# confirms that holds rather than assuming it.
static:
  doAssert not compiles(default(AsyncCallback).context),
    "`context` getter must not leak through the public API. It lives " &
    "in chronos/futures.nim, excluded from `asyncengine.nim`'s " &
    "`export futures`, and is used by the dispatcher's " &
    "`fireWithContext` only."
  doAssert not compiles(default(InternalCancelCallback).context),
    "`InternalCancelCallback`'s `context` getter must not leak through " &
    "the public API either — same exclusion, same reasoning, used by " &
    "the dispatcher's `fireCancelCallback` only (RFC 0001 D5)."

# --- A trivial runtime assertion to keep the test file unittest-recognized ---

suite "contextvars: public surface":
  test "compile-time guardrails passed":
    # Reaching this line means every `static:` / `when` check above
    # passed. The compile-time checks are the actual guardrails; this
    # test exists only so the test runner reports a green dot.
    check true
