## RFC 0001 D9-V / S9 — index primitives under verification.
##
## **FORK-ONLY. Never imported by, referenced by, or coupled to any
## upstream-bound file.** See `verify/README.md`.
##
## W3 (uint wraparound counters): this file used to be a textual mirror
## of `chronos/internal/callbackqueue.nim`'s five index primitives,
## hand-kept in sync and cross-checked by `drift_check.nim`. It is now
## an `include` of the real module instead: layers 1-2 (this file's
## callers, `symex_checks.nim` and `callbackqueue_model.nim`) prove
## properties of the SHIPPED code directly, with no mirror to drift out
## of sync in the first place. `include`, not `import`: the five
## primitives are private to `chronos/internal/callbackqueue.nim` (no
## `*`) by design (see that file's own module doc) - `include` splices
## the file's AST into this one, making its private top-level names
## visible here exactly as if they had been written in this file
## (Nim's privacy boundary is per-module, and after `include` there is
## only one module). Callers of THIS file must, in turn, `include
## ./primitives` rather than `import` it, for the same reason -
## `import` would only see `*`-exported names, and re-exporting the
## five primitives under new names would mean proving properties of
## thin wrappers one indirection away from the real procs, not the
## real procs themselves.
##
## The included file's `{.push raises: [], gcsafe.}` (no matching
## `{.pop.}` - each module implicitly pops its own pushes at its own
## end, which is exactly the boundary `include` erases) would otherwise
## leak that pragma onto every subsequent declaration in this file and
## every file that further imports it. The `{.pop.}` immediately below
## is the corrective - empirically confirmed necessary and sufficient
## (a small standalone repro: an included file's unbalanced `push`
## reaches a `raise` two files downstream unless a `pop` closes it
## first at the include site).
##
## `symex_checks.nim`/`callbackqueue_model.nim` go back to `import
## ./primitives` (not `include`), through the five thin, `{.inline.}`,
## logic-free wrappers below - NOT the included names directly. Two
## reasons: (1) the included file also brings in the real
## `CallbackQueue[T]` type and its own `initCallbackQueue`/`addLast`/
## `popFirst`/`grow` - `callbackqueue_model.nim` deliberately declares
## ITS OWN same-named versions of exactly those for its ghost-ownership
## model, which a transitive `include` would collide with; (2) the five
## real primitives have no `*` (private by design - only
## `chronos/internal/callbackqueue.nim`'s own public five entry points
## are meant to be reachable), and a same-named exported redeclaration
## in this scope is a hard duplicate-definition error regardless of the
## star, so re-exporting needs distinct names either way. A thin
## `{.inline.}` pass-through with no logic of its own proves nothing
## different from proving the real proc directly - symex's
## interprocedural walker already resolves one call-frame of plain
## `proc`-to-`proc` indirection (it does so today resolving
## `slotIndex`'s own call into `capMask`), so this adds no semantic gap.

include ../chronos/internal/callbackqueue
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
