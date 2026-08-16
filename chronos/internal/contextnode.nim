#
#                     Tonalli
#
#        (c) Copyright 2026-Present Corey Leavitt
#
#    Licensed under the Apache License, Version 2.0
#               (LICENSE-APACHEv2)

## Base type of the continuation-local binding chain — split into its own
## dependency-free leaf module so `chronos/futures.nim` can import it (for
## `InternalAsyncCallback`'s `context` field type) without exporting it.
##
## The `next` field is private to this module: every `contextVar`
## declaration emits its own nameable `ref object of ContextNodeBase`
## subtype, so a public field would let user code link a node into a
## cycle without ever naming the base type. Keeping it private confines
## chain mutation to `linkNode` below.

{.push raises: [].}

type
  ContextNodeBase* = ref object of RootObj
    ## Base of the per-task continuation-local binding chain. Each
    ## `contextVar` declaration emits a `ref object of ContextNodeBase`
    ## subtype with its own `value: T` field; the chain is heterogeneous
    ## in value type and the walker uses Nim's runtime type test (`of`)
    ## to find the right slot.
    next: ContextNodeBase
      ## Private — read via `nextNode`, written via `linkNode` only.

func nextNode*(node: ContextNodeBase): ContextNodeBase {.inline.} =
  ## Read-only chain traversal for the walkers in `contextvars_impl.nim`.
  node.next

proc linkNode*(node, prev: ContextNodeBase) {.inline.} =
  ## Link a freshly-constructed slot node to the chain head it is about
  ## to shadow. Call exactly once per node, before the node is published
  ## as the new chain head.
  node.next = prev
