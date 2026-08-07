#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Drift-detection guardrails for chronos's context-variable feature.
##
## Each check is a compile-time assertion (`static:` / `when compiles`)
## pinning capture discipline, chain privacy, and struct layout so
## regressions fail at build time rather than at runtime.

import unittest2
import ../chronos/internal/contextvars_impl
import ../chronos/futures
import ../chronos/contextvars

{.used.}

# --- Guardrail 1: capture coverage is structural -----------------------------
#
# InternalAsyncCallback's fields are private to chronos/futures.nim;
# only userCallback/bareCallback/contextCallback can construct one.

static:
  doAssert not compiles(InternalAsyncCallback(function: nil, udata: nil)),
    "InternalAsyncCallback's fields must be private — raw construction " &
    "outside `userCallback`/`bareCallback`/`contextCallback` must not " &
    "compile. Use `userCallback(fn, udata)` for user-facing scheduling " &
    "sites, `bareCallback(fn, udata)` for chronos-internal trampolines, " &
    "or `contextCallback(fn, udata, ctx)` to reconstruct a callback from " &
    "a context captured earlier (Windows IOCP completion dispatch). " &
    "See docs/src/contextvars.md, 'Capture discipline'."
  doAssert not compiles((var a: AsyncCallback; a.function = nil)),
    "AsyncCallback's `function` field must be private — direct mutation " &
    "outside chronos/futures.nim must not compile."
  doAssert not compiles((var a: AsyncCallback; a.context = nil)),
    "AsyncCallback's `context` field must be private — direct mutation " &
    "would let a scheduling site silently skip context capture."

# --- Guardrail 2: context is a native ref, not a manually-refcounted pointer -
#
# A `pointer` field would need manual GC_ref/GC_unref at every drop
# site — a latent leak under --mm:refc since keepItIf's shallowCopy
# bypasses hooks. The native ref delegates lifecycle to Nim's MM.

static:
  doAssert InternalAsyncCallback.context is ContextNodeBase,
    "InternalAsyncCallback.context must be `ContextNodeBase` (a native " &
    "`ref` field) — see docs/src/contextvars.md, 'Implementation'. A " &
    "`pointer` field with " &
    "manual GC_ref/unref leaks under refc via `keepItIf`'s shallowCopy, " &
    "and forces every new scheduling site to remember the manual ops."

# --- Guardrail 3: AsyncCallback layout stable --------------------------------
#
# If the struct gains a field or changes layout, this assertion drifts.
# A cheap canary against accidental shape changes.

static:
  # CallbackFunc closure proc = 2 pointers (function + env), plus
  # udata (1) and context: ContextNodeBase (a ref, 1 pointer) = 4.
  doAssert sizeof(InternalAsyncCallback) == sizeof(pointer) * 4,
    "InternalAsyncCallback expected to be 4 pointer-sized fields " &
    "(function: 2-word closure proc, udata: pointer, context: ref); " &
    "actual size = " & $sizeof(InternalAsyncCallback)

# Guardrail 4 (public surface is minimal) lives in
# tests/testcontextvarssurface.nim, which imports only public paths.

# --- Guardrail 5: the binding chain is immutable outside contextnode.nim -----
#
# ContextNodeBase.next must stay private: each contextVar arm emits a
# nameable subtype inheriting the field, so a public `next` would let
# user code write `mySlot.next = mySlot`, cycling contextLookup's walk
# or rewriting a chain shared with pending callbacks.

contextVar:
  var chainProbe: int = 0

static:
  doAssert compiles(ChainProbeSlot(value: 1)),
    "control: this module declared the arm, so constructing its slot " &
    "with `value` must compile here — if this fails, the checks below " &
    "are not probing what they claim to probe"
  doAssert not compiles((var n: ContextNodeBase; n.next)),
    "ContextNodeBase.next must not be readable outside contextnode.nim " &
    "— traversal goes through the internal `nextNode` getter only."
  doAssert not compiles((var n: ContextNodeBase; n.next = n)),
    "ContextNodeBase.next must not be writable outside contextnode.nim " &
    "— chain links are written by `linkNode` exactly once per node."
  doAssert not compiles((var s = ChainProbeSlot(value: 1); s.next = s)),
    "a slot SUBTYPE must not reach the inherited `next` field either — " &
    "the emitted slot types are nameable, so a public field would " &
    "reopen the cycle attack without ever naming ContextNodeBase."
  doAssert not compiles((cast[ChainProbeSlot](currentAsyncContext).next = nil)),
    "`cast` must not defeat this: casting yields the subtype, but field " &
    "access is still privacy-checked per-module, so even a cast of the " &
    "live chain head cannot mutate a link."

# --- Guardrail 6: InternalCancelCallback --------------------------------------
#
# Same structural-privacy discipline as InternalAsyncCallback above,
# mirrored for this 3-word type (no udata field).

static:
  doAssert not compiles(InternalCancelCallback(function: nil, context: nil)),
    "InternalCancelCallback's fields must be private — raw construction " &
    "outside `newCancelCallback` (or the no-capture site in " &
    "`internalInitFutureBase`) must not compile. Use " &
    "`newCancelCallback(fn)`. See docs/src/contextvars.md, 'Capture " &
    "discipline'."
  doAssert not compiles((var c: InternalCancelCallback; c.function = nil)),
    "InternalCancelCallback's `function` field must be private — direct " &
    "mutation outside chronos/futures.nim must not compile."
  doAssert not compiles((var c: InternalCancelCallback; c.context = nil)),
    "InternalCancelCallback's `context` field must be private — direct " &
    "mutation would let a scheduling site silently skip context capture."

  doAssert InternalCancelCallback.context is ContextNodeBase,
    "InternalCancelCallback.context must be `ContextNodeBase` (a native " &
    "`ref` field) — same MM-delegated lifetime discipline as " &
    "`InternalAsyncCallback.context` (guardrail 2 above)."

  # CallbackFunc closure proc (2 words) + context: ContextNodeBase (1) = 3.
  doAssert sizeof(InternalCancelCallback) == sizeof(pointer) * 3,
    "InternalCancelCallback expected to be 3 pointer-sized fields " &
    "(function: 2-word closure proc, context: ref); " &
    "actual size = " & $sizeof(InternalCancelCallback)

# --- Guardrail 7: the introspection registry is not externally mutable ------
#
# `.name`/`.render` are public (the declaring module's macro-generated
# code constructs entries), but `.registered`/`.next` must stay private
# to contextvars_impl.nim — a reachable `.next` would let code splice
# or unlink registry nodes, corrupting dumpContext's walk.

contextVar:
  var registryProbe: int = 0

static:
  doAssert compiles(registryProbeContextVarReg.name),
    "control: this module declared the arm, so its registration " &
    "node's public `name` field must be readable here — otherwise " &
    "the probe below is vacuous"
  doAssert not compiles(registryProbeContextVarReg.registered),
    "ContextVarRegistration.registered must not be readable outside " &
    "contextvars_impl.nim."
  doAssert not compiles(registryProbeContextVarReg.next),
    "ContextVarRegistration.next must not be readable outside " &
    "contextvars_impl.nim — a reachable link primitive would reopen " &
    "the cycle/unlink attack the registry's append-only design closes."
  doAssert not compiles((registryProbeContextVarReg.next = nil)),
    "ContextVarRegistration.next must not be writable outside " &
    "contextvars_impl.nim either."

# --- A trivial runtime assertion to keep the test file unittest-recognized ---

suite "contextvars: drift guardrails":
  test "compile-time guardrails passed":
    # The static checks above are the real guardrails; this just
    # gives the runner a green dot.
    check true
