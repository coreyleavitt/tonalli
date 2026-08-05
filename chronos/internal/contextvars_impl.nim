## Continuation-local storage — per-slot lookup/bind primitives.
##
## This module is NOT part of chronos's public API. Users interact via
## `chronos/contextvars.nim` which exports only the `contextVar` macro,
## `AsyncContext` opaque type, `currentContext()`, and `withContext()`.
## The primitives here are imported by the macro's generated code
## only — the dispatcher-facing pieces (`currentAsyncContext`, the
## `userCallback`/`internalCallback` constructor split) live in
## `chronos/futures.nim` alongside the `InternalAsyncCallback` type
## they construct; see that module's §Continuation-local context.
##
## See `docs/src/contextvars.md` for the design rationale.
##
## ## Slot-typed subtype hierarchy
##
## Each `contextVar` declaration emits a fresh `ref object of
## ContextNodeBase` subtype with a `value: T` field. The chain is a
## linked list of `ContextNodeBase`; the macro-generated reader walks
## the chain with `if node of FooSlot: return FooSlot(node).value`.
## The slot owns the value inline — no pointer-to-stack-local, so
## `currentContext()` snapshots remain sound after the originating
## binder exits.

import ../futures
import ./contextnode
export ContextNodeBase
# `currentAsyncContext` itself is declared in `chronos/futures.nim`;
# re-exported (not re-declared) here so `chronos/contextvars.nim` can
# reach it via this module alone, same as `ContextNodeBase` above.
# `futures` itself is never `export`ed onward from here — only this
# one symbol is forwarded — so this does not widen what's reachable
# via `import chronos/contextvars`.
export currentAsyncContext

when defined(chronosDebug):
  var chainBalance* {.threadvar.}: int
    ## Debug-only bind/unbind balance counter. `contextBindSlot`
    ## increments at slot push, decrements at slot pop. A nonzero value
    ## at test-suite end signals a binder leak (a `with*` that pushed
    ## a slot but never restored). Deterministic + MM-portable —
    ## doesn't depend on GC sweep timing.

  proc chainLen*(): int {.inline, raises: [].} =
    ## Debug-only chain-depth probe. Walks `currentAsyncContext` and
    ## returns the number of nodes. Used by binder-contract tests to
    ## verify push/pop balance without relying on finalizer timing.
    ## Gated with `chainBalance` because both are test helpers
    ## with non-trivial production cost (O(depth) walk) and no user
    ## use case outside verification.
    var n = currentAsyncContext
    while n != nil:
      inc result
      n = n.nextNode

# --- Per-slot lookup / bind primitives ---------------------------------------
# Used by the macro-generated `name()` / `withName(v, body)` templates.
# `N` is the slot type (a `ref object of ContextNodeBase` subtype with
# a `value: T` field); `T` is its value type. Both are inferred at
# macro-emission time.

proc contextLookup*[N: ContextNodeBase; T](default: T): T {.gcsafe, raises: [].} =
  ## Walk the chain looking for a node of type `N`. Return its `value`
  ## field (copied for value types, shared for ref types) if found,
  ## else return `default`.
  ##
  ## INTERNAL — invoked by macro-generated readers.
  {.cast(gcsafe).}:
    var node = currentAsyncContext
    while node != nil:
      if node of N:
        return N(node).value
      node = node.nextNode
    default

template contextBindSlot*[N: ContextNodeBase; T](v: T, body: untyped) =
  ## Push a new `N` slot owning `v` onto the chain for the dynamic
  ## extent of `body`; restore the prior head on every exit path.
  ## The slot OWNS `v` (stored in its `value` field) — no
  ## pointer-to-stack-local, so a snapshot captured during `body`
  ## remains sound after `body` exits.
  ##
  ## INTERNAL — invoked by macro-generated binders.
  ##
  ## Hygiene: the local `chronosCtxPrev` `let` binding is auto-
  ## gensym'd by Nim's standard template hygiene (no `{.dirty.}`),
  ## so nesting this template inside `withContext` (which uses the
  ## same name) is safe — each expansion gets a unique binding.
  ## The macro-emitted `withName` template's PARAMETERS
  ## (`chronosCtxV`, `chronosCtxBody`) are NOT gensym'd — those
  ## use the `chronosCtx` prefix to minimize collision risk with
  ## user-code identifiers inside the body.
  let chronosCtxPrev = currentAsyncContext
  # Construction and linking are split: `value` is private to the slot
  # type's declaring module (settable here because this template expands
  # under that module's macro-emitted binder), while `next` is private
  # to `contextnode.nim` and writable only through `linkNode`. The node
  # is allocated before any global state changes, so an allocation
  # failure cannot leave a half-pushed chain.
  let chronosCtxNode = N(value: v)
  linkNode(chronosCtxNode, chronosCtxPrev)
  currentAsyncContext = chronosCtxNode
  when defined(chronosDebug):
    inc chainBalance
  try:
    body
  finally:
    currentAsyncContext = chronosCtxPrev
    when defined(chronosDebug):
      dec chainBalance
