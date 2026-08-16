## Index primitives under verification.
##
## **FORK-ONLY. Never imported by, referenced by, or coupled to any
## upstream-bound file.** See `verify/README.md`.
##
## `include`s the real `chronos/internal/callbackqueue.nim` rather than
## mirroring it, so callers here (`symex_checks.nim`, `callbackqueue_model.nim`)
## prove the shipped primitives directly, with nothing left to drift.
## `include`, not `import`: the five primitives are private (no `*`) by
## design, and `include` splices the file's AST into this one so private
## names are visible as if written here. Callers of THIS file must, in
## turn, `include ./primitives` rather than `import` it, for the same
## reason.
##
## The included file's `{.push raises: [], gcsafe.}` has no matching
## `{.pop.}` of its own (each module pops its own pushes at its own end -
## a boundary `include` erases), so it would otherwise leak onto every
## later declaration here and in further importers. The `{.pop.}` below
## is the corrective.
##
## `symex_checks.nim`/`callbackqueue_model.nim` go back to `import
## ./primitives` (not `include`), through the five thin, `{.inline.}`,
## logic-free wrappers below rather than the included names directly:
## the included file also brings in the real `CallbackQueue[T]` type and
## its own `initCallbackQueue`/`addLast`/`popFirst`/`grow`, which would
## collide with `callbackqueue_model.nim`'s own same-named ghost-model
## declarations. The primitives themselves have no `*`, so re-exporting
## needs distinct names regardless. A thin pass-through with no logic of
## its own proves nothing different from proving the real proc directly.

include ../tonalli/internal/callbackqueue
{.pop.}

proc capMaskV*(cap: int): uint {.inline.} =
  capMask(cap)

proc slotIndexV*(pos: uint, cap: int): int {.inline.} =
  slotIndex(pos, cap)

proc queueLenV*(head, tail: uint): int {.inline.} =
  queueLen(head, tail)

proc isFullV*(head, tail: uint, cap: int): bool {.inline.} =
  isFull(head, tail, cap)

proc growTargetCapV*(cap: int): int {.inline.} =
  growTargetCap(cap)
