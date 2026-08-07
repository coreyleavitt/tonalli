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

proc contextLookupChain[N: ContextNodeBase; T](
    chain: ContextNodeBase, default: T): T {.inline, gcsafe, raises: [].} =
  ## Walk `chain` looking for a node of type `N`; return its `value`
  ## field (copied for value types, shared for ref types) if found,
  ## else return `default`. Shared walker: `contextLookup` (ambient
  ## chain) and `contextLookupSnapshot` (caller-supplied chain) both
  ## delegate here, so the lookup semantics have exactly one
  ## implementation; `{.inline.}` folds the indirection back out.
  var node = chain
  while node != nil:
    if node of N:
      return N(node).value
    node = node.nextNode
  default

proc contextLookup*[N: ContextNodeBase; T](default: T): T {.gcsafe, raises: [].} =
  ## Walk the ambient chain looking for a node of type `N`. Return its
  ## `value` field (copied for value types, shared for ref types) if
  ## found, else return `default`.
  ##
  ## INTERNAL — invoked by macro-generated readers.
  {.cast(gcsafe).}:
    contextLookupChain[N, T](currentAsyncContext, default)

proc contextLookupSnapshot*[N: ContextNodeBase; T](
    chain: ContextNodeBase, default: T): T {.gcsafe, raises: [].} =
  ## Snapshot variant of `contextLookup`: walk `chain` (typically the
  ## chain underlying a captured `AsyncContext`) instead of the
  ## ambient `currentAsyncContext`. Does not install `chain` — this is
  ## a read, not a bind.
  ##
  ## INTERNAL — invoked by macro-generated snapshot readers
  ## (`name(ctx: AsyncContext)`).
  contextLookupChain[N, T](chain, default)

proc contextFindChain[N: ContextNodeBase; T](
    chain: ContextNodeBase): tuple[found: bool, value: T]
    {.inline, gcsafe, raises: [].} =
  ## Walk `chain` for a node of type `N`, reporting whether one was
  ## found instead of folding a miss into a default — must-bind arms
  ## need to distinguish "unbound" from "bound to the zero value" to
  ## raise `UnboundContextVarDefect` (chronos/contextvars.nim)
  ## correctly. Shared by `contextFind` and `contextFindSnapshot`
  ## below, same one-implementation discipline as `contextLookupChain`.
  var node = chain
  while node != nil:
    if node of N:
      return (true, N(node).value)
    node = node.nextNode

proc contextFind*[N: ContextNodeBase; T](): tuple[found: bool, value: T]
    {.gcsafe, raises: [].} =
  ## Ambient must-bind probe. INTERNAL — invoked by macro-generated
  ## readers for default-less (`var name: T`) arms, which raise
  ## `UnboundContextVarDefect` when `found` is false. Kept raise-free
  ## here — the Defect type lives in the public
  ## `chronos/contextvars.nim` and is raised there, not in this
  ## internal module.
  {.cast(gcsafe).}:
    contextFindChain[N, T](currentAsyncContext)

proc contextFindSnapshot*[N: ContextNodeBase; T](
    chain: ContextNodeBase): tuple[found: bool, value: T] {.gcsafe, raises: [].} =
  ## Snapshot counterpart of `contextFind`. Also the primitive
  ## `dumpContext` uses, via each arm's generated render proc, to
  ## report an arm's bound/unbound state and value within a snapshot.
  contextFindChain[N, T](chain)

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

# --- Introspection registry -------------------------------------------------
#
# Intrusive, allocation-free registry of every declared `contextVar` arm,
# so `dumpContext` can enumerate them without a GC-managed collection.
# Each arm emits one module-level `ContextVarRegistration` global and
# links it into `contextVarRegistryHead` from that module's init
# statements — see the `contextVar` macro.

type
  ContextVarRenderProc* = proc(chain: ContextNodeBase):
    tuple[bound: bool, rendered: string] {.nimcall, gcsafe, raises: [].}
    ## Per-arm introspection renderer emitted by the `contextVar`
    ## macro. Reports whether the arm is bound in `chain`, and a `$`-
    ## rendered (or placeholder) string of its value either way — the
    ## bound value if bound, else the rendered default (defaulted
    ## arms) or a fixed placeholder (must-bind arms). INTERNAL —
    ## invoked by `dumpContext` via the registry only.

  ContextVarRegistration* = object
    ## Intrusive registry node for one `contextVar` arm, emitted as a
    ## module-level global by the macro. Plain `object`, not `ref`:
    ## `name` and `render` involve no GC-tracked memory, so linking one
    ## of these into the registry allocates nothing.
    name*: cstring
    render*: ContextVarRenderProc
    registered: bool
    next: ptr ContextVarRegistration

var contextVarRegistryHead: ptr ContextVarRegistration
  ## Head of the global registry list. A single process-wide global,
  ## not `{.threadvar.}` — one registry regardless of thread count.
  ## Thread-safety invariant scoped to a static single-binary
  ## deployment: module init runs on the main thread before any
  ## `createThread` is possible, so it is write-once-then-read-only
  ## and needs no lock. See docs/src/contextvars.md, "Inspecting
  ## contexts" for the shared-library/dlopen caveat.

proc registerContextVar*(node: ptr ContextVarRegistration) {.gcsafe, raises: [].} =
  ## Link `node` into the global registry, idempotently. Called once
  ## per `contextVar` arm, from that arm's module-level init
  ## statements (emitted by the macro). See `contextVarRegistryHead`
  ## for the thread-safety invariant this relies on.
  if not node.registered:
    node.registered = true
    node.next = contextVarRegistryHead
    contextVarRegistryHead = node

iterator contextVarRegistry*(): ptr ContextVarRegistration {.raises: [].} =
  ## Walk every registered `contextVar` arm. INTERNAL — used by
  ## `dumpContext` only.
  var n = contextVarRegistryHead
  while n != nil:
    yield n
    n = n.next
