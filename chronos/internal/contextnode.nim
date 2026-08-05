#
#                     Chronos
#
#  (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-2025 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Base type of the continuation-local binding chain — split into its own
## dependency-free leaf module so `chronos/futures.nim` can IMPORT it (for
## `InternalAsyncCallback`'s `context` field type) WITHOUT exporting it.
##
## Two layers keep the chain immutable against user code:
##
## 1. The type itself is unnameable from public imports. `futures.nim`
##    is re-exported through `asyncengine.nim` -> `asyncloop.nim` ->
##    `chronos.nim`: anything `futures.nim` itself exports becomes
##    reachable via plain `import chronos`. Keeping the type in its own
##    leaf module — imported, never exported, by `futures.nim` — means a
##    user cannot convert an `AsyncContext` snapshot back to the base
##    type (`distinct` -> base conversion is legal only where the base
##    type is nameable).
## 2. The `next` field is private to THIS module. Unnameability alone is
##    not enough: every `contextVar` declaration emits a *nameable*
##    `ref object of ContextNodeBase` subtype, which inherits `next` —
##    were the field public, user code could write `mySlot.next = mySlot`
##    through its own slot type without ever naming the base, building a
##    cycle that hangs `contextLookup`'s walk forever (or rewriting a
##    live chain shared by reference with pending callbacks). With the
##    field private, chain links are written only by `linkNode` below —
##    called exactly once per node, by `contextBindSlot`, before the node
##    becomes reachable — so no code outside this module can mutate a
##    chain through any *named* access, checked or `cast`. (Nim's
##    `fieldPairs`/`fields` reflection ignores field visibility and can
##    still reach the link on a dereferenced node; deliberate reflection
##    over chronos internals is outside the threat model, same as
##    `import chronos/internal/*`.)
##
## See docs/src/contextvars.md §Capture discipline.

type
  ContextNodeBase* = ref object of RootObj
    ## Base of the per-task continuation-local binding chain. Each
    ## `contextVar` declaration emits a `ref object of ContextNodeBase`
    ## subtype with its own `value: T` field; the chain is heterogeneous
    ## in value type and the walker uses Nim's runtime type test (`of`)
    ## to find the right slot.
    next: ContextNodeBase
      ## Private — see the module doc's layer 2. Read via `nextNode`,
      ## written via `linkNode` only.

proc nextNode*(node: ContextNodeBase): ContextNodeBase {.inline, raises: [].} =
  ## INTERNAL — read-only chain traversal for the walkers in
  ## `contextvars_impl.nim` (`contextLookup`, `chainLen`). Reading
  ## cannot corrupt the chain, so a getter is safe to export from this
  ## internal module; it is not reachable from public imports (pinned
  ## in tests/testcontextvarssurface.nim).
  node.next

proc linkNode*(node, prev: ContextNodeBase) {.inline, raises: [].} =
  ## INTERNAL — link a freshly-constructed slot node to the chain head
  ## it is about to shadow. Called exactly once per node, by
  ## `contextBindSlot` only, before the node is published as the new
  ## chain head — never on a node that is already part of a chain.
  node.next = prev
