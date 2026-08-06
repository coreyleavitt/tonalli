#
#                     Chronos
#
#  (c) Copyright 2026-Present Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

## Continuation-local storage for chronos.
##
## A `contextVar` declaration introduces a dynamically-scoped binding
## that propagates through async boundaries: every reader inside the
## same logical task sees the same value, even across `await`
## suspensions, while concurrent tasks remain isolated.
##
## Usage:
##
##   contextVar:
##     var currentUser: User = anonymous
##
##   proc handler() {.async.} =
##     withCurrentUser(authedUser):
##       let result = await db.query(...)
##       audit(currentUser(), result)    # currentUser() == authedUser
##
## An arm may omit its default (`var name: T`, no `= default`) to
## declare a must-bind variable instead: reading it while unbound
## raises `UnboundContextVarDefect` rather than falling back to a
## value. See docs/src/contextvars.md, "Required variables".
##
## ## Public API
##
## - `contextVar`: declaration macro (block form: see usage above).
##   Per arm, generates a slot type (`ref object of ContextNodeBase`
##   with a `value: T` field), an ambient reader `name()`, a snapshot
##   reader `name(ctx: AsyncContext)`, and a scoped binder
##   `withName(v): body`.
## - `currentContext()` / `withContext(ctx, body)`: snapshot/restore for
##   callback-style code that runs under a context captured earlier —
##   e.g. independently-fired enter/exit hooks that don't go through
##   `await`. See docs/src/contextvars.md for details.
## - `` `==`(a, b: AsyncContext): bool `` — identity equality between
##   two snapshots.
## - `dumpContext(ctx: AsyncContext): seq[ContextVarEntry]` / `` `$`
##   (ctx: AsyncContext): string `` — introspect every declared arm's
##   state within a snapshot. See "Inspecting contexts" in
##   docs/src/contextvars.md.
## - `UnboundContextVarDefect`: raised by a must-bind arm's reader
##   (ambient or snapshot) when read while unbound.
##
## `ContextNodeBase` and the per-slot `contextLookup`/`contextBindSlot`
## primitives are internal, living in
## `chronos/internal/contextvars_impl.nim`.

import std/[macros, strutils]
import ./internal/contextvars_impl

# --- Public type: opaque snapshot ------------------------------------------

type AsyncContext* = distinct ContextNodeBase

proc `==`*(a, b: AsyncContext): bool {.gcsafe, raises: [].} =
  ## Identity equality: `true` iff `a` and `b` reference the same
  ## underlying chain head — i.e. both were captured with no
  ## intervening binding change. Two `currentContext()` calls with no
  ## `withName`/`withContext` between them compare equal; capturing
  ## again from inside a new binder produces a distinct, unequal
  ## snapshot. Comparison is by ref identity (the chain head pointer),
  ## not by walking and comparing bindings — two chains with the same
  ## bindings but built independently are NOT equal.
  ContextNodeBase(a) == ContextNodeBase(b)

proc currentContext*(): AsyncContext {.gcsafe, raises: [].} =
  ## Capture the current task's binding chain as an opaque snapshot.
  ## Pair with `withContext(ctx, body)` to run code later under the
  ## context that was current at capture time — useful for
  ## callback-style code that fires from the dispatcher outside of
  ## `await` and needs to restore the context from registration time.
  ##
  ## The snapshot remains valid after the originating binder exits. It
  ## is thread-affine: do not send it to, or restore it on, another
  ## thread.
  ##
  ## Async procs awaiting futures do not need this — chronos's
  ## dispatcher propagates context through `await` automatically.
  {.cast(gcsafe).}:
    AsyncContext(currentAsyncContext)

template withContext*(ctx: AsyncContext, body: untyped) =
  ## Run `body` with `ctx` as the current async context; restore the
  ## prior context on every exit path (normal, exception, including
  ## `CancelledError`).
  ##
  ## Unlike the macro-generated `withName` (which prefixes its params
  ## to avoid colliding with contextVar names), `ctx`/`body` use plain
  ## names here — template hygiene still resolves identifiers inside
  ## `body` against the caller's scope, not the param.
  let chronosCtxPrev = currentAsyncContext
  currentAsyncContext = ContextNodeBase(ctx)
  try:
    body
  finally:
    currentAsyncContext = chronosCtxPrev

# --- Must-bind support ------------------------------------------------------

type
  UnboundContextVarDefect* = object of Defect
    ## Raised by a must-bind arm's reader (`var name: T`, no `=
    ## default`) when read while unbound — the PEP 567 analog of a
    ## default-less `ContextVar`. A `Defect`, not a `CatchableError`:
    ## reading an unbound must-bind var is a contract violation (the
    ## caller forgot to `withName` first), not a recoverable runtime
    ## condition, and `Defect`s sit outside Nim's `raises` effect
    ## tracking — so an `{.async: (raises: []).}` proc can read
    ## must-bind context vars without widening its raises list for a
    ## condition that signals a bug rather than an expected failure
    ## mode. See docs/src/contextvars.md, "Required variables".

proc contextRequire[N: ContextNodeBase; T](varName: string): T
    {.gcsafe, raises: [].} =
  ## Ambient must-bind lookup: like the generated defaulted reader,
  ## but raises `UnboundContextVarDefect` instead of returning a
  ## default when no binder is in scope. INTERNAL — invoked only by
  ## macro-generated readers for default-less (`var name: T`) arms.
  let r = contextFind[N, T]()
  if not r.found:
    raise newException(UnboundContextVarDefect,
      "context variable '" & varName & "' has no default and is not " &
      "bound in the current context")
  r.value

proc contextRequireSnapshot[N: ContextNodeBase; T](
    chain: ContextNodeBase, varName: string): T {.gcsafe, raises: [].} =
  ## Snapshot counterpart of `contextRequire`, for the generated
  ## `name(ctx: AsyncContext)` snapshot reader on a must-bind arm.
  let r = contextFindSnapshot[N, T](chain)
  if not r.found:
    raise newException(UnboundContextVarDefect,
      "context variable '" & varName & "' has no default and is not " &
      "bound in the given snapshot")
  r.value

# --- Declaration macro -----------------------------------------------------

macro contextVar*(body: untyped): untyped =
  ## Declare one or more context variables. Block syntax:
  ##
  ##   contextVar:
  ##     var currentUser: User = anonymous
  ##     var requestId: string = ""
  ##     var traceId: string        # must-bind: no default
  ##
  ## Each arm is a `var name: T = default` declaration, or — for a
  ## must-bind arm — `var name: T` with no `= default` at all. The
  ## `var` keyword is required for parse-stability: without it, Nim's
  ## command-with-do-block parser claims the colon before the macro
  ## sees `name: T = v` as `nnkExprColonExpr`.
  ##
  ## The arm name's `*` export marker controls the visibility of
  ## everything the arm generates: `var name*: T = default` produces
  ## an exported reader/binder/slot type; `var name: T = default` (no
  ## star) produces a module-private trio. A single block may mix
  ## starred and non-starred, and defaulted and must-bind, arms.
  ##
  ## For each arm, generates at module scope:
  ##
  ## 1. `type NameSlot = ref object of ContextNodeBase` with `value: T`
  ##    — a fresh subtype per declaration, so distinct declarations
  ##    never alias each other's storage.
  ## 2. `template name(): T` — reader; returns the current binding for
  ##    this task. For a defaulted arm, returns `default` if no
  ##    binding is in scope (`default` is re-evaluated on every
  ##    unbound call rather than computed once at declaration time —
  ##    keep it cheap and side-effect-free). For a must-bind arm,
  ##    raises `UnboundContextVarDefect` if no binding is in scope —
  ##    see docs/src/contextvars.md, "Required variables".
  ## 3. `template name(ctx: AsyncContext): T` — snapshot reader; same
  ##    semantics as the reader above, but reads the binding recorded
  ##    in `ctx` (a snapshot from `currentContext()`) instead of the
  ##    ambient chain, without installing it.
  ## 4. `template withName(v: T, body: untyped)` — scoped binder;
  ##    binds `v` for the dynamic extent of `body`, restores on every
  ##    exit path. The slot owns `v` inline, so a `currentContext()`
  ##    snapshot captured inside `body` remains sound after `body`
  ##    exits.
  ##
  ## Every arm — defaulted or must-bind — also registers itself with
  ## the allocation-free introspection registry that `dumpContext`
  ## walks; see "Inspecting contexts" in docs/src/contextvars.md.
  ##
  ## The `var name` from the input is NOT emitted as a runtime variable
  ## — the macro reuses var-section syntax purely for its parse
  ## properties.
  expectKind(body, nnkStmtList)
  result = newStmtList()
  for section in body:
    if section.kind == nnkCommentStmt: continue
    if section.kind != nnkVarSection:
      error("contextVar: each arm must be `var name: T = default` or " &
            "`var name: T` (must-bind); got " & section.repr, section)
    for identDefs in section:
      if identDefs.kind == nnkCommentStmt: continue
      if identDefs.len != 3:
        error("contextVar: each arm must be a single `var name: T = " &
              "default` or `var name: T` (must-bind)", identDefs)
      let nameIdent  = identDefs[0]
      let typExpr    = identDefs[1]
      let defaultVal = identDefs[2]
      # A missing default (`var name: T`, no `= default`) is legal —
      # it declares a must-bind arm: reading while unbound raises
      # `UnboundContextVarDefect` instead of falling back to a value.
      # Nim's parser requires an explicit type when there is no value
      # to infer one from, so `typExpr` is never empty here — a bare
      # `var name` with neither type nor value is already a parse
      # error before this macro ever sees it.
      let isMustBind = defaultVal.kind == nnkEmpty
      if typExpr.kind == nnkEmpty:
        error("contextVar: each arm must declare an explicit type " &
              "(`var name: T = default` or `var name: T`); type " &
              "inference from the default is not supported", identDefs)
      # Accept `nnkSym` alongside `nnkIdent`/`nnkPostfix` so this macro
      # composes from other macros — e.g., a wrapper that builds the
      # arm name via `genSym`. `$node` stringifies all forms; the
      # emitted slot type, reader, and binder always get fresh
      # `nnkIdent`s, so the public surface is regular identifiers
      # regardless of how the arm name arrived.
      if nameIdent.kind notin {nnkIdent, nnkSym, nnkPostfix}:
        error("contextVar: arm name must be an identifier (pragmas not " &
              "supported)", nameIdent)
      let isExported = nameIdent.kind == nnkPostfix
      let rawBareName =
        if isExported:
          # Nim's parser only emits `nnkPostfix` for the `*` export
          # marker; assert defensively in case that ever changes.
          if not nameIdent[0].eqIdent("*"):
            error("contextVar: unsupported postfix operator on arm name",
                  nameIdent)
          nameIdent[1]
        else:
          nameIdent
      let name = $rawBareName
      # Normalize to a fresh `nnkIdent` for emission. An incoming
      # `nnkSym` of kind `nskVar` (from a wrapper macro's `genSym`)
      # can't be reused as a template name — Nim rejects with
      # "cannot use symbol of kind 'var' as a 'template'". Going
      # through `ident($node)` produces a regular identifier and
      # avoids the kind mismatch.
      let bareName = ident(name)
      # Slot type name: capitalize first char + "Slot" suffix.
      # ASCII-only identifiers (Nim convention); non-ASCII names are
      # rejected upstream by Nim's identifier parser.
      let slotTypeName = ident(toUpperAscii(name[0]) & name[1 .. ^1] & "Slot")
      let withName = ident("with" & toUpperAscii(name[0]) & name[1 .. ^1])
      # Definition-site name nodes: `*`-postfixed when the arm was
      # exported, bare otherwise. `slotTypeName`/`bareName`/`withName`
      # themselves stay bare — they're also used unmarked in
      # reference position below (`contextLookup[slotTypeName, ...]`
      # etc.), where a postfix node would be a syntax error.
      let slotTypeNameDef =
        if isExported: nnkPostfix.newTree(ident"*", slotTypeName) else: slotTypeName
      let bareNameDef =
        if isExported: nnkPostfix.newTree(ident"*", bareName) else: bareName
      let withNameDef =
        if isExported: nnkPostfix.newTree(ident"*", withName) else: withName
      # A second definition-site node for the snapshot reader overload
      # (`name(ctx: AsyncContext)`) — built fresh rather than reusing
      # `bareNameDef`, since that node (a postfix tree, when exported)
      # is already spliced into the ambient reader's `quote do` below;
      # a fresh node avoids relying on whether Nim's `quote`
      # implementation tolerates splicing the same node object twice.
      let bareNameCtxDef =
        if isExported: nnkPostfix.newTree(ident"*", bareName) else: bareName
      let nameLit = newLit(name)
      let typeNameLit = newLit(typExpr.repr)
      let readerProcName = ident(name & "ContextVarRender")
      let regNodeName = ident(name & "ContextVarReg")
      # The snapshot reader's parameter, built once as an actual
      # `NimNode` and backtick-substituted everywhere it's needed
      # (both the template's parameter list, spliced later, and its
      # body here). A bare (non-backtick) `chronosCtxSnap` written
      # separately in two different `quote do` invocations does NOT
      # reliably bind to "the same" identifier when the assembled
      # template is later instantiated — `quote` resolves an
      # unrecognized bare identifier as an open symbol at the
      # template's *call site*, not necessarily against a same-named
      # parameter declared by a sibling `quote do` call. Splicing the
      # identical node object sidesteps that: it's unambiguously the
      # same parameter in both places, exactly like this file's
      # existing pattern of reusing `typExpr`/`slotTypeName` in
      # multiple `quote do` positions.
      let chronosCtxSnapIdent = ident("chronosCtxSnap")
      # Reader bodies differ by arm kind; everything else (slot type,
      # binder, registration) is identical either way.
      let readerBody =
        if isMustBind:
          quote do: contextRequire[`slotTypeName`, `typExpr`](`nameLit`)
        else:
          quote do: contextLookup[`slotTypeName`, `typExpr`](`defaultVal`)
      let snapshotReaderBody =
        if isMustBind:
          quote do:
            contextRequireSnapshot[`slotTypeName`, `typExpr`](
              ContextNodeBase(`chronosCtxSnapIdent`), `nameLit`)
        else:
          quote do:
            contextLookupSnapshot[`slotTypeName`, `typExpr`](
              ContextNodeBase(`chronosCtxSnapIdent`), `defaultVal`)
      # The render proc's not-found branch: must-bind arms show a
      # fixed placeholder (dumpContext never raises — introspection is
      # total); defaulted arms show the default, `$`-rendered when
      # possible, else the same "<T>" placeholder a non-`$`-able bound
      # value would get below.
      #
      # The `when compiles(...)` probe is deliberately run against a
      # freshly zero-initialized `var` of the arm's declared, concrete
      # type — not against `defaultVal` (the raw default expression
      # AST) directly, and not via `system.default` (a `var` gives the
      # same "value of this exact type" disambiguation with a
      # construct that hasn't changed meaning across Nim versions this
      # series targets). A bare polymorphic literal default like `nil`
      # has no fixed type of its own: `compiles($(nil))` can silently
      # resolve `$` against an unrelated type `nil` also happens to be
      # compatible with (e.g. `cstring`'s `$`, which calls `strlen` on
      # it) rather than failing the way `$` genuinely does for the
      # arm's own type (e.g. a bare `ptr T`) — and then *evaluating*
      # that wrongly-resolved overload on the actual `nil` default is a
      # null-pointer read. Gating on a `var` of type `typExpr`
      # (unambiguously typed) avoids the misresolution; the render
      # itself still uses `defaultVal` so the *value* shown is the
      # arm's actual declared default, not `typExpr`'s zero value.
      let notFoundTuple =
        if isMustBind:
          quote do: (false, "<unbound>")
        else:
          quote do:
            when compiles((block:
              var chronosCtxZero: `typExpr`
              $chronosCtxZero)):
              (false, $(`defaultVal`))
            else:
              (false, "<" & `typeNameLit` & ">")
      result.add quote do:
        type `slotTypeNameDef` = ref object of ContextNodeBase
          ## Slot type for this `contextVar` declaration. Each
          ## declaration emits a fresh `ref object of ContextNodeBase`
          ## subtype; the runtime walker uses `of` to find the matching
          ## slot in the per-task binding chain.
          value: `typExpr`

        template `bareNameDef`(): `typExpr` =
          ## Read the current binding for this contextVar. A defaulted
          ## arm returns the declared default if no binder is
          ## currently in scope; a must-bind arm raises
          ## `UnboundContextVarDefect` instead. Lookup walks the
          ## per-task binding chain; the innermost binder wins (LIFO).
          `readerBody`

        template `bareNameCtxDef`(`chronosCtxSnapIdent`: AsyncContext): `typExpr` =
          ## Read the binding recorded in the given snapshot (from
          ## `currentContext()`) without installing it — same
          ## bound/default/must-bind semantics as the ambient reader
          ## above, applied to the snapshot's chain instead of the
          ## current task's.
          `snapshotReaderBody`

        template `withNameDef`(chronosCtxV: `typExpr`, chronosCtxBody: untyped) =
          ## Bind a value for the dynamic extent of the body. Restores
          ## the prior binding on every exit path (normal return,
          ## exception, `CancelledError`). The binding propagates
          ## through `await` for any async code executed within the
          ## body; the dispatcher captures the current binding chain
          ## at every scheduling site and restores it at fire time.
          contextBindSlot[`slotTypeName`, `typExpr`](
            chronosCtxV, chronosCtxBody)

        proc `readerProcName`(chronosCtxChain: ContextNodeBase):
            tuple[bound: bool, rendered: string] {.nimcall, gcsafe, raises: [].} =
          ## Introspection renderer for this arm — see
          ## `ContextVarRenderProc`. INTERNAL: reached only through
          ## the registry, by `dumpContext`.
          let chronosCtxR = contextFindSnapshot[`slotTypeName`, `typExpr`](chronosCtxChain)
          if chronosCtxR.found:
            when compiles($(chronosCtxR.value)):
              (true, $(chronosCtxR.value))
            else:
              (true, "<" & `typeNameLit` & ">")
          else:
            `notFoundTuple`

        var `regNodeName`: ContextVarRegistration = ContextVarRegistration(
          name: cstring(`nameLit`), render: `readerProcName`)
        registerContextVar(addr `regNodeName`)

# --- Introspection -----------------------------------------------------------

type
  ContextVarEntry* = object
    ## One `dumpContext` entry: one `contextVar` arm's state within a
    ## particular snapshot.
    name*: string
    bound*: bool
      ## `true` iff this arm has a binding on the chain `dumpContext`
      ## was called with. `false` for both an unbound defaulted arm
      ## (`value` is still shown — the default it would read as) and
      ## an unbound must-bind arm (`value` is a fixed placeholder).
    value*: string
      ## `$`-rendered when the arm's value type has a `$` (checked via
      ## `when compiles`); otherwise a placeholder of the form `<T>`.

proc dumpContext*(ctx: AsyncContext): seq[ContextVarEntry] {.raises: [].} =
  ## Introspect every declared `contextVar` arm — across every module
  ## loaded into the program, defaulted or must-bind — as of the given
  ## snapshot.
  ##
  ## Every declared arm appears exactly once, whether bound in `ctx`
  ## or not: an unbound defaulted arm is shown with `bound: false` and
  ## the value it would actually read as (the rendered default); an
  ## unbound must-bind arm is shown with `bound: false` and a fixed
  ## placeholder — `dumpContext` never raises `UnboundContextVarDefect`
  ## the way the arm's own reader would. This is the more
  ## useful-for-debugging choice: a debugger or log dump wants to see
  ## the whole declared universe and each var's actual state, not just
  ## the subset that happens to be bound right now.
  ##
  ## Cost: proportional to the number of `contextVar` arms declared
  ## anywhere in the program (one allocation-free registry walk) plus
  ## one `$`-render per arm — paid only when `dumpContext` is called,
  ## never on the reader/binder/capture/fire hot paths.
  {.cast(gcsafe).}:
    let chain = ContextNodeBase(ctx)
    for node in contextVarRegistry():
      let (bound, rendered) = node.render(chain)
      result.add ContextVarEntry(name: $node.name, bound: bound, value: rendered)

proc `$`*(ctx: AsyncContext): string {.raises: [].} =
  ## Render `ctx` as `{name: value, ...}`, via the same registry walk
  ## as `dumpContext`. Intended for debugging/logging, not for parsing
  ## — the format is not guaranteed stable across chronos versions.
  var parts: seq[string]
  for entry in dumpContext(ctx):
    parts.add entry.name & ": " & entry.value
  "{" & parts.join(", ") & "}"
