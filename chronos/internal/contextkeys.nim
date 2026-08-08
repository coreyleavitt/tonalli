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
## name at re-fold time. This slice covers construction, the
## intrusive registry, and the render-proc generic-into-nimcall
## construction only — ambient reads, `withValue`, and `` `[]` `` are
## later slices.

import ./contextnode
export ContextNodeBase

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

  ContextNode*[T] = ref object of ContextNodeBase
    ## One chain node: the key it was bound under, plus the owned
    ## value. Lands here for later slices' binder/lookup use.
    key: ContextVarBase
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
