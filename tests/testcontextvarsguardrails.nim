## Drift-detection guardrails for chronos's context-variable feature.
##
## These tests catch regressions that would silently break the
## architectural decisions in `docs/src/contextvars.md`. Each is
## structured as a compile-time check (`static:` / `when`) so drift
## fails at build time, not at runtime.
##
## The properties guarded here — compile-time slot identity rather
## than a runtime tag comparison, value-owning slots rather than
## storage reached through a box or pointer, and structurally enforced
## capture coverage rather than a convention contributors have to
## remember — are each easy to erode one call site at a time with no
## compiler error to catch it.

import unittest2
import ../chronos/internal/contextvars_impl
import ../chronos/futures
import ../chronos/contextvars

{.used.}

# --- Guardrail 1: capture coverage is structural -----------------------------
#
# The two-constructor split (userCallback / internalCallback) forces
# every AsyncCallback construction site to pick a deliberate side.
# `InternalAsyncCallback`'s `function`/`udata`/`context` fields are
# private to `chronos/futures.nim` — only `userCallback`/
# `internalCallback` can construct one, and no other module can
# read-modify the fields after the fact.

static:
  doAssert not compiles(InternalAsyncCallback(function: nil, udata: nil)),
    "InternalAsyncCallback's fields must be private — raw construction " &
    "outside `userCallback`/`internalCallback` must not compile. Use " &
    "`userCallback(fn, udata)` for user-facing scheduling sites or " &
    "`internalCallback(fn, udata)` for chronos-internal trampolines. " &
    "See docs/src/contextvars.md, 'Capture discipline'."
  doAssert not compiles((var a: AsyncCallback; a.function = nil)),
    "AsyncCallback's `function` field must be private — direct mutation " &
    "outside chronos/futures.nim must not compile."
  doAssert not compiles((var a: AsyncCallback; a.context = nil)),
    "AsyncCallback's `context` field must be private — direct mutation " &
    "would let a scheduling site silently skip context capture."

# --- Guardrail 2: context is a native ref, not a manually-refcounted pointer
#
# A `context: pointer` field would need manual `GC_ref`/`GC_unref` and
# an explicit release call at every drop site — a latent leak under
# `--mm:refc`, where e.g. sequtils' `keepItIf` uses `shallowCopy` and
# bypasses hooks. The native-ref field instead delegates refcount
# lifecycle to Nim's MM.

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
  # CallbackFunc is `proc(arg: pointer) {.gcsafe, raises: [].}` — a Nim
  # closure proc, 2 pointers (function + env). Plus `udata: pointer`
  # (1 pointer) and `context: ContextNodeBase` (a ref, 1 pointer).
  # Total: 4 pointers — a `ref` is a single machine word, so the
  # native-ref field costs nothing extra over a raw `pointer` field.
  doAssert sizeof(InternalAsyncCallback) == sizeof(pointer) * 4,
    "InternalAsyncCallback expected to be 4 pointer-sized fields " &
    "(function: 2-word closure proc, udata: pointer, context: ref); " &
    "actual size = " & $sizeof(InternalAsyncCallback)

# Guardrail 4 (public surface is minimal) lives in
# `tests/testcontextvarssurface.nim` — it needs to import
# ONLY the public `chronos`/`chronos/contextvars` paths, which this
# file can't do since it needs the internal modules for the white-box
# checks above.

# --- Guardrail 5: the binding chain is immutable outside contextnode.nim -----
#
# `ContextNodeBase.next` must stay private to `chronos/internal/
# contextnode.nim`. Keeping the base type unnameable from public imports
# is NOT sufficient on its own: every `contextVar` declaration emits a
# nameable subtype that inherits the field, so a public `next` would let
# user code write `mySlot.next = mySlot` through its own slot type — a
# cycle that hangs `contextLookup`'s walk, or a rewrite of a live chain
# shared by reference with pending callbacks. This module imports the
# internal modules directly and STILL must not reach the field: privacy
# is per-module, so these checks hold everywhere outside contextnode.nim
# itself.

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
# `internalCancelcb` was slimmed from the shared 4-word `InternalAsyncCallback`
# to a dedicated 3-word type: the `udata` field it carried was provably
# redundant (every construction site stored `cast[pointer](future)`, and
# the fire site already has `future` in scope to derive it). Same
# structural-privacy discipline as `InternalAsyncCallback` above, so the
# same three checks, mirrored for the new type.

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

  # CallbackFunc is a 2-word closure proc (function + env). Plus
  # `context: ContextNodeBase` (a ref, 1 word). Total: 3 words — 8 B
  # smaller than InternalAsyncCallback's 4 words.
  doAssert sizeof(InternalCancelCallback) == sizeof(pointer) * 3,
    "InternalCancelCallback expected to be 3 pointer-sized fields " &
    "(function: 2-word closure proc, context: ref); " &
    "actual size = " & $sizeof(InternalCancelCallback)

# --- A trivial runtime assertion to keep the test file unittest-recognized ---

suite "contextvars: drift guardrails":
  test "compile-time guardrails passed":
    # Reaching this line means every `static:` / `when` check above
    # passed. The compile-time checks are the actual guardrails;
    # this test exists only so the test runner reports a green dot.
    check true
