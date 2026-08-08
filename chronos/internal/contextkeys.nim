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
## chain-walk lookup, and `withValue`. Must-bind Defect parity,
## snapshot `` `[]` ``/`AsyncContext`, the registry-consuming
## `dumpContext`, and the `{.contextVar.}` declaration sugar are
## later slices.

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

# --- The one chain-walk lookup -----------------------------------------------
# Slice 4 re-expresses `.value` as `currentContext()[cv]`, on top of the
# same `lookupChain` — kept as the sole walk so that re-expression is a
# thin wrapper, not a second implementation.

proc lookupChain[T](chain: ContextNodeBase, cv: ContextVar[T]): T {.raises: [].} =
  var node = chain
  while node != nil:
    if cast[ContextNodeKeyed](node).key == ContextVarBase(cv):
      return cast[ContextNode[T]](node).value
    node = node.nextNode
  if cv.hasDefault:
    cv.default
  else:
    # Placeholder only: must-bind Defect parity (message + `varName`)
    # is slice 5. This is the smallest honest miss behavior until then.
    raise newException(Defect, "unbound context variable: " & cv.name)

proc lookupAmbient[T](cv: ContextVar[T]): T {.gcsafe, raises: [].} =
  ## Mirrors `contextvars_impl.nim`'s `contextLookup`: reading the
  ## ambient `currentAsyncContext` threadvar isn't provably gcsafe to
  ## the compiler, hence the escape hatch.
  {.cast(gcsafe).}:
    lookupChain(currentAsyncContext, cv)

template value*[T](cv: ContextVar[T]): T =
  lookupAmbient(cv)

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
