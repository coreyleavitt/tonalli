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
## ## Public API
##
## - `contextVar`: declaration macro (block form: see usage above).
##   Generates a slot type (`ref object of ContextNodeBase` with a
##   `value: T` field), a reader `name()`, and a scoped binder
##   `withName(v): body` per arm.
## - `currentContext()` / `withContext(ctx, body)`: snapshot/restore for
##   callback-style code that runs under a context captured earlier —
##   e.g. independently-fired enter/exit hooks that don't go through
##   `await`. See docs/src/contextvars.md for details.
##
## `ContextNodeBase` and the per-slot `contextLookup`/`contextBindSlot`
## primitives are internal, living in
## `chronos/internal/contextvars_impl.nim`.

import std/[macros, strutils]
import ./internal/contextvars_impl

# --- Public type: opaque snapshot ------------------------------------------

type AsyncContext* = distinct ContextNodeBase

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

# --- Declaration macro -----------------------------------------------------

macro contextVar*(body: untyped): untyped =
  ## Declare one or more context variables. Block syntax:
  ##
  ##   contextVar:
  ##     var currentUser: User = anonymous
  ##     var requestId: string = ""
  ##
  ## Each arm is a `var name: T = default` declaration. The `var`
  ## keyword is required for parse-stability: without it, Nim's
  ## command-with-do-block parser claims the colon before the macro
  ## sees `name: T = v` as `nnkExprColonExpr`.
  ##
  ## The arm name's `*` export marker controls the visibility of
  ## everything the arm generates: `var name*: T = default` produces
  ## an exported reader/binder/slot type; `var name: T = default` (no
  ## star) produces a module-private trio. A single block may mix
  ## starred and non-starred arms.
  ##
  ## For each arm, generates at module scope:
  ##
  ## 1. `type NameSlot = ref object of ContextNodeBase` with `value: T`
  ##    — a fresh subtype per declaration, so distinct declarations
  ##    never alias each other's storage.
  ## 2. `template name(): T` — reader; returns the current binding for
  ##    this task, or `default` if no binding is in scope. `default`
  ##    is re-evaluated on every unbound call rather than computed once
  ##    at declaration time — keep it cheap and side-effect-free.
  ## 3. `template withName(v: T, body: untyped)` — scoped binder;
  ##    binds `v` for the dynamic extent of `body`, restores on every
  ##    exit path. The slot owns `v` inline, so a `currentContext()`
  ##    snapshot captured inside `body` remains sound after `body`
  ##    exits.
  ##
  ## The `var name` from the input is NOT emitted as a runtime variable
  ## — the macro reuses var-section syntax purely for its parse
  ## properties.
  expectKind(body, nnkStmtList)
  result = newStmtList()
  for section in body:
    if section.kind == nnkCommentStmt: continue
    if section.kind != nnkVarSection:
      error("contextVar: each arm must be `var name: T = default`; got " &
            section.repr, section)
    for identDefs in section:
      if identDefs.kind == nnkCommentStmt: continue
      if identDefs.len != 3:
        error("contextVar: each arm must be a single `var name: T = default`",
              identDefs)
      let nameIdent  = identDefs[0]
      let typExpr    = identDefs[1]
      let defaultVal = identDefs[2]
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
      result.add quote do:
        type `slotTypeNameDef` = ref object of ContextNodeBase
          ## Slot type for this `contextVar` declaration. Each
          ## declaration emits a fresh `ref object of ContextNodeBase`
          ## subtype; the runtime walker uses `of` to find the matching
          ## slot in the per-task binding chain.
          value: `typExpr`

        template `bareNameDef`(): `typExpr` =
          ## Read the current binding for this contextVar, or return
          ## the declared default if no binder is currently in scope.
          ## Lookup walks the per-task binding chain; the innermost
          ## binder wins (LIFO).
          contextLookup[`slotTypeName`, `typExpr`](`defaultVal`)

        template `withNameDef`(chronosCtxV: `typExpr`, chronosCtxBody: untyped) =
          ## Bind a value for the dynamic extent of the body. Restores
          ## the prior binding on every exit path (normal return,
          ## exception, `CancelledError`). The binding propagates
          ## through `await` for any async code executed within the
          ## body; the dispatcher captures the current binding chain
          ## at every scheduling site and restores it at fire time.
          contextBindSlot[`slotTypeName`, `typExpr`](
            chronosCtxV, chronosCtxBody)
