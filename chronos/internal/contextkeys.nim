#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## First-class `ContextVar[T]` key runtime — spike for the redesign in
## `.claude/rfc/0002-contextvars-firstclass-keys.handoff.md`.
##
## Transitional module: lands alongside the `contextVar` macro
## (`chronos/contextvars.nim`) without changing it; takes its final
## name at re-fold time. Covers construction, the intrusive registry,
## the render-proc generic-into-nimcall construction, the ambient
## chain-walk lookup, `withValue`, the snapshot `` `[]` ``/`AsyncContext`
## pair, and must-bind `UnboundContextVarDefect` parity. The
## registry-consuming `dumpContext` and the `{.contextVar.}` declaration
## sugar are later slices.

import std/hashes
import ../futures
import ./contextnode
export ContextNodeBase
# `currentAsyncContext` is declared in `chronos/futures.nim`; mirrors the
# single-symbol re-export discipline `contextvars_impl.nim` uses.
export currentAsyncContext

type
  ContextVarBase* = ref object of RootRef
    ## Non-generic base of a `ContextVar[T]` key. Ref identity IS key
    ## identity: no `==`/`hash` is ever defined for this hierarchy.
    name*: string
    hasDefault*: bool
    private*: bool
    render*: proc(node: ContextNodeBase): string {.nimcall, gcsafe, raises: [].}
    nextRegistered: ContextVarBase

  ContextVar*[T] = ref object of ContextVarBase
    default: T

  ContextNodeKeyed = ref object of ContextNodeBase
    ## Carries `key` where every chain node can read it without
    ## knowing `T` — `contextnode.nim`'s real `ContextNodeBase` is
    ## off-limits (shared with the old macro design) and declares
    ## only `next`, so this layer inserts the field the lookup walk
    ## needs, one level below it. `ContextNode[T]` is the only type
    ## ever built on this layer, so `key`'s presence at this offset
    ## is sound by construction, not by runtime tag.
    key: ContextVarBase

  ContextNode*[T] = ref object of ContextNodeKeyed
    ## One chain node: the key it was bound under, plus the owned
    ## value.
    value: T

var registryHead: ContextVarBase
  ## Head of the intrusive registry list — process-lifetime, allocation
  ## free. Registration keeps a key alive for the life of the process,
  ## matching the old macro design's static-global semantics.

proc renderGeneric[T](node: ContextNodeBase): string {.nimcall, gcsafe, raises: [].} =
  let v = cast[ContextNode[T]](node).value
  when T is ref:
    if v == nil:
      "nil"
    else:
      when compiles($(v)):
        try:
          $(v)
        except CatchableError:
          "<render-error>"
      else:
        "<no-$>"
  else:
    when compiles($(v)):
      try:
        $(v)
      except CatchableError:
        "<render-error>"
    else:
      "<no-$>"

proc registerVar(base: ContextVarBase) =
  base.nextRegistered = registryHead
  registryHead = base

proc newContextVar*[T](name: string, default: T, private = false): ContextVar[T] =
  ## Defaulted-arm constructor.
  result = ContextVar[T](name: name, hasDefault: true, private: private,
                          default: default)
  result.render = renderGeneric[T]
  if not private:
    registerVar(result)

proc newContextVar*[T](name: string, private = false): ContextVar[T] =
  ## Must-bind arm constructor — no default supplied.
  result = ContextVar[T](name: name, hasDefault: false, private: private)
  result.render = renderGeneric[T]
  if not private:
    registerVar(result)

iterator registeredVars*(): ContextVarBase =
  var node = registryHead
  while node != nil:
    yield node
    node = node.nextRegistered

proc renderDefault*[T](cv: ContextVar[T]): string =
  ## Test-support helper: render `cv`'s stored default through its
  ## render hook without a bound chain node — there is no binder in
  ## this slice. Exercises the generic-instantiated-into-nimcall
  ## construction end-to-end.
  let node = ContextNode[T](key: cv, value: cv.default)
  cv.render(node)

# --- Snapshot type and the one chain-walk lookup -----------------------------
# `.value` re-expresses as `currentContext()[cv]` below, on top of this
# same `` `[]` `` — the sole walk, so the re-expression is a thin wrapper,
# not a second implementation.

type
  AsyncContext* = distinct ContextNodeBase
    ## Opaque snapshot of a binding chain, captured by `currentContext()`.
    ## Transitional: mirrors `chronos/contextvars.nim`'s type of the same
    ## name exactly (identity semantics); the two are unified at re-fold.

proc `==`*(a, b: AsyncContext): bool {.gcsafe, raises: [].} =
  ContextNodeBase(a) == ContextNodeBase(b)

proc hash*(ctx: AsyncContext): Hash {.gcsafe, raises: [].} =
  hash(cast[pointer](ContextNodeBase(ctx)))

proc currentContext*(): AsyncContext {.gcsafe, raises: [].} =
  ## Capture the current task's binding chain as an opaque snapshot.
  {.cast(gcsafe).}:
    AsyncContext(currentAsyncContext)

type
  UnboundContextVarDefect* = object of Defect
    ## Raised by a must-bind key's read (`.value` or `ctx[cv]`) when no
    ## binding is in scope. Message parity with
    ## `chronos/contextvars.nim`'s `UnboundContextVarDefect`, with one
    ## resolved divergence: since `.value` routes through `` `[]` ``,
    ## the wording can't distinguish ambient from snapshot at zero cost
    ## (the old module's two callsites could; this one can't without a
    ## per-callsite string param, rejected as not worth it for wording
    ## alone). Both paths use the old module's snapshot wording.
    varName*: string

proc `[]`*[T](ctx: AsyncContext, cv: ContextVar[T]): T {.raises: [].} =
  var node = ContextNodeBase(ctx)
  while node != nil:
    if cast[ContextNodeKeyed](node).key == ContextVarBase(cv):
      return cast[ContextNode[T]](node).value
    node = node.nextNode
  if cv.hasDefault:
    cv.default
  else:
    var e = newException(UnboundContextVarDefect,
      "context variable '" & cv.name & "' has no default and is not " &
      "bound in this context")
    e.varName = cv.name
    raise e

template value*[T](cv: ContextVar[T]): T =
  currentContext()[cv]

template withValue*[T](cv: ContextVar[T], v: T, body: untyped): untyped =
  ## Push a `ContextNode[T]` bound to `cv` onto the ambient chain for
  ## the dynamic extent of `body`; restore the prior head on every
  ## exit path. Mirrors `contextBindSlot`'s ordering: allocate before
  ## mutating `currentAsyncContext`, so a failed allocation can't leave
  ## a half-pushed chain. Debug-mode `chainBalance` accounting stays
  ## with the old binder in `contextvars_impl.nim` for this slice —
  ## carried over at the port slice, not duplicated here.
  let chronosCtxPrev = currentAsyncContext
  let chronosCtxNode = ContextNode[T](key: cv, value: v)
  linkNode(chronosCtxNode, chronosCtxPrev)
  currentAsyncContext = chronosCtxNode
  try:
    body
  finally:
    currentAsyncContext = chronosCtxPrev
