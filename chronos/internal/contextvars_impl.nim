#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Continuation-local storage — per-slot lookup/bind primitives.
##
## Not part of chronos's public API: users interact via
## `chronos/contextvars.nim`, which exports only the `contextVar`
## macro, `AsyncContext`, `currentContext()`, and `withContext()`. The
## primitives here are used by the macro's generated code only.
##
## See `docs/src/contextvars.md` for the full design.
##
## ## Slot-typed subtype hierarchy
##
## Each `contextVar` declaration emits a fresh `ref object of
## ContextNodeBase` subtype with a `value: T` field. The chain is a
## linked list of `ContextNodeBase`; the macro-generated reader walks
## it with `if node of FooSlot: return FooSlot(node).value`. The slot
## owns the value inline — no pointer-to-stack-local — so
## `currentContext()` snapshots remain sound after the originating
## binder exits.

import ../futures
import ./contextnode
export ContextNodeBase
# `currentAsyncContext` is declared in `chronos/futures.nim`; only
# this one symbol is re-exported here (not all of `futures`), so this
# does not widen `chronos/contextvars`'s public surface.
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
  ## Hygiene: `chronosCtxPrev` is gensym'd by Nim's standard template
  ## hygiene, so nesting this inside `withContext` (same local name) is
  ## safe. The macro-emitted `withName`'s parameters (`chronosCtxV`,
  ## `chronosCtxBody`) are NOT gensym'd — they use the `chronosCtx`
  ## prefix instead to avoid colliding with user code in `body`.
  let chronosCtxPrev = currentAsyncContext
  # `value` is settable here (this template expands under the slot
  # type's declaring module); `next` is only settable via `linkNode`.
  # Allocating before mutating global state means an allocation
  # failure can't leave a half-pushed chain.
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
