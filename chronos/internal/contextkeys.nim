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
## pair, must-bind `UnboundContextVarDefect` parity, `dumpContext`/
## `` `$` ``, and the `{.contextVar.}` declaration sugar.

import std/[algorithm, hashes, macros, strutils]
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
    render*: proc(cv: ContextVarBase, node: ContextNodeBase): string
      {.nimcall, gcsafe, raises: [].}
      ## `node == nil` renders the key's stored default instead of a
      ## bound node's value — the one instantiation `dumpContext`
      ## needs for both the bound and the unbound-but-defaulted case.
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

proc renderValue[T](v: T): string {.raises: [].} =
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

proc renderGeneric[T](cv: ContextVarBase, node: ContextNodeBase): string
    {.nimcall, gcsafe, raises: [].} =
  if node != nil:
    renderValue(cast[ContextNode[T]](node).value)
  else:
    renderValue(ContextVar[T](cv).default)

when defined(chronosDebug):
  var contextVarConstructionLocked = false
    ## Guard flag for the write-once-then-read-only registry discipline
    ## the RFC documents ("Registry and key lifetime"): keys are
    ## constructed only before any `createThread`. Flipped by
    ## `lockContextVarConstruction()`; chronos's own thread-creation
    ## path does not call it yet — wiring that in is deferred to final
    ## assembly. Debug-only: no lock is paid on any path in a release
    ## build.

  proc lockContextVarConstruction*() {.inline.} =
    ## Engage the construction guard. Any `newContextVar` call after
    ## this point asserts. One-way for the process's lifetime — there
    ## is no matching unlock, mirroring the real thread-creation event
    ## it stands in for.
    contextVarConstructionLocked = true

  proc checkContextVarConstructionAllowed() {.inline.} =
    doAssert not contextVarConstructionLocked,
      "newContextVar called after lockContextVarConstruction() — keys " &
      "must be constructed before any thread creation"

proc registerVar(base: ContextVarBase) =
  base.nextRegistered = registryHead
  registryHead = base

proc newContextVar*[T](name: string, default: T, private = false): ContextVar[T] =
  ## Defaulted-arm constructor.
  when defined(chronosDebug): checkContextVarConstructionAllowed()
  result = ContextVar[T](name: name, hasDefault: true, private: private,
                          default: default)
  result.render = renderGeneric[T]
  if not private:
    registerVar(result)

proc newContextVar*[T](name: string, private = false): ContextVar[T] =
  ## Must-bind arm constructor — no default supplied.
  when defined(chronosDebug): checkContextVarConstructionAllowed()
  result = ContextVar[T](name: name, hasDefault: false, private: private)
  result.render = renderGeneric[T]
  if not private:
    registerVar(result)

iterator registeredVars*(): ContextVarBase =
  var node = registryHead
  while node != nil:
    yield node
    node = node.nextRegistered

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

# --- Introspection ------------------------------------------------------------
# CONTRACT PARITY with `chronos/contextvars.nim`'s `dumpContext`/`` `$` ``:
# same `ContextVarEntry` shape, same bound-flag semantics (an unbound
# defaulted key still shows its rendered default; an unbound must-bind
# key shows the `<unbound>` placeholder), same sorted-by-name order,
# same `{name: value, ...}` `$` format. Private keys never register
# (see `newContextVar`), so they are structurally absent here — no
# filtering needed at this layer.

type
  ContextVarEntry* = object
    name*: string
    bound*: bool
    value*: string

proc findNode(chain: ContextNodeBase, cv: ContextVarBase): ContextNodeBase =
  var node = chain
  while node != nil:
    if cast[ContextNodeKeyed](node).key == cv:
      return node
    node = node.nextNode

proc dumpContext*(ctx: AsyncContext): seq[ContextVarEntry] {.raises: [].} =
  ## Introspect every registered (non-private) key as of `ctx`, sorted
  ## by name. Never raises — render failures are caught inside each
  ## key's render hook.
  {.cast(gcsafe).}:
    let chain = ContextNodeBase(ctx)
    for cv in registeredVars():
      let node = findNode(chain, cv)
      if node != nil:
        result.add ContextVarEntry(name: cv.name, bound: true,
                                    value: cv.render(cv, node))
      elif cv.hasDefault:
        result.add ContextVarEntry(name: cv.name, bound: false,
                                    value: cv.render(cv, nil))
      else:
        result.add ContextVarEntry(name: cv.name, bound: false,
                                    value: "<unbound>")
  result.sort(proc(a, b: ContextVarEntry): int = cmp(a.name, b.name))

proc `$`*(ctx: AsyncContext): string {.raises: [].} =
  ## Render `ctx` as `{name: value, ...}`, via the same registry walk
  ## as `dumpContext`. Debugging/logging only — not a stable format.
  var parts: seq[string]
  for entry in dumpContext(ctx):
    parts.add entry.name & ": " & entry.value
  "{" & parts.join(", ") & "}"

# --- `{.contextVar.}` declaration sugar --------------------------------------
# Ported from `.claude/rfc/0002-hybrid-prototype/sugar.nim`. A pragma
# macro, not a statement macro: `contextVar name*: T = default` doesn't
# parse (export postfix and identdef are `let`/`var`-only parser
# productions). Attached as `{.contextVar.}` between the star and the
# colon-type, it lets the parser's own identdef grammar do the
# star/type/default parsing; the macro only rewrites the RHS into a
# `newContextVar` call and re-emits the one `let`/`var` symbol.

proc splitContextVarNameAndPrivate(identNode: NimNode):
    tuple[nameNode: NimNode, nameStr: string, private: bool] =
  ## Star present -> exported -> private = false; absent -> private =
  ## true. `nnkIdent`/`nnkSym` both resolve via `strVal` (a wrapper
  ## template forwarding its own parameter arrives as `nnkSym`); only
  ## `nnkPostfix` needs unwrapping to reach the name.
  case identNode.kind
  of nnkPostfix:
    doAssert identNode.len == 2 and identNode[0].strVal == "*",
      "contextVar: unexpected postfix form: " & identNode.repr
    (identNode, identNode[1].strVal, false)
  of nnkIdent, nnkSym:
    (identNode, identNode.strVal, true)
  else:
    error("contextVar: expected `name` or `name*`, got " & identNode.repr, identNode)

macro contextVar*(def: untyped): untyped =
  ## `let name* {.contextVar.} = default` (T inferred), `let name*
  ## {.contextVar.}: T = default` (explicit T), or `var name*
  ## {.contextVar.}: T` (must-bind) — expands to exactly one symbol,
  ## `let name* = newContextVar(...)`. See the handoff's "Declaration
  ## sugar" for the pinned form.
  doAssert def.kind in {nnkLetSection, nnkVarSection},
    "contextVar must annotate a `let` or `var` statement"
  doAssert def.len == 1, "contextVar supports exactly one identifier per statement"
  let identDefs = def[0]
  doAssert identDefs.kind == nnkIdentDefs and identDefs.len == 3
  let (nameNode, nameStr, private) = splitContextVarNameAndPrivate(identDefs[0])
  let typAnnotation = identDefs[1]
  let value = identDefs[2]

  let ctorCall =
    if value.kind == nnkEmpty:
      doAssert typAnnotation.kind != nnkEmpty,
        "contextVar: must-bind keys need an explicit type, e.g. `var x*: T {.contextVar.}`"
      quote do: newContextVar[`typAnnotation`](`nameStr`, private = `private`)
    elif typAnnotation.kind != nnkEmpty:
      quote do: newContextVar[`typAnnotation`](`nameStr`, `value`, private = `private`)
    else:
      quote do: newContextVar(`nameStr`, `value`, private = `private`)

  result = newNimNode(nnkLetSection)
  result.add newIdentDefs(nameNode, newEmptyNode(), ctorCall)
