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
##   callback-style code that needs to run under a context captured
##   earlier (synchronous-callback boundaries that don't go through
##   `await`) — the tool for independently-fired enter/exit hooks; see
##   docs/src/contextvars.md §Bridging independent callbacks.
##
## Internals are NOT part of chronos's public API: `ContextNodeBase`
## and the per-slot `contextLookup`/`contextBindSlot` primitives live
## in `chronos/internal/contextvars_impl.nim`; the `currentAsyncContext`
## threadvar and the dispatcher hooks `userCallback`/`internalCallback`
## live in `chronos/futures.nim`, excluded from `asyncengine.nim`'s
## re-export of that module so they don't leak through `import chronos`.

import std/[macros, strutils]
import ./internal/contextvars_impl

# --- Public type: opaque snapshot ------------------------------------------

type AsyncContext* = distinct ContextNodeBase

proc currentContext*(): AsyncContext {.gcsafe, raises: [].} =
  ## Capture the current task's binding chain as an opaque snapshot.
  ## Pair with `withContext(ctx, body)` to run code under that snapshot
  ## later — used by callback-style code that fires from the dispatcher
  ## with whatever context happens to be current and wants to restore
  ## the context that was current at registration.
  ##
  ## The snapshot keeps the chain alive via Nim's normal refcounting;
  ## it remains sound after the originating binder exits, because each
  ## slot owns its value inline (the value isn't stored at a
  ## pointer-to-stack-local that would dangle).
  ##
  ## The snapshot is thread-affine: the chain is thread-local,
  ## garbage-collected memory — do not send it to, or restore it on,
  ## another thread. See docs/src/contextvars.md §Bridging independent
  ## callbacks.
  ##
  ## Async procs awaiting futures do NOT need this — chronos's dispatcher
  ## propagates context through `await` automatically.
  {.cast(gcsafe).}:
    AsyncContext(currentAsyncContext)

template withContext*(ctx: AsyncContext, body: untyped) =
  ## Run `body` with `ctx` as the current async context; restore the
  ## prior context on every exit path (normal, exception, including
  ## `CancelledError`).
  ##
  ## Param names `ctx`/`body` are unprefixed (unlike the macro-emitted
  ## `withName(chronosCtxV, chronosCtxBody)` which uses the prefix to
  ## avoid collision with user-declared contextVar names). Nim's
  ## template hygiene preserves identifiers inside the substituted
  ## `body` — a user `let ctx = x; withContext(s): echo ctx` resolves
  ## the inner `ctx` against the caller's scope, not the param.
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
  ## Each arm is a `var name: T = default` declaration. (The `var`
  ## keyword is required for parse-stability — without it, Nim's
  ## command-with-do-block parser claims the colon and `name: T = v`
  ## doesn't reach the macro as `nnkExprColonExpr`.)
  ##
  ## The arm name's `*` export marker controls the visibility of
  ## everything the arm generates: `var name*: T = default` produces
  ## an exported reader/binder/slot type, reachable from importing
  ## modules; `var name: T = default` (no star) produces a
  ## module-private trio, invisible outside the declaring module. Each
  ## arm's marker is independent — a single block may mix starred and
  ## non-starred arms.
  ##
  ## For each arm, generates at module scope:
  ##
  ## 1. `type NameSlot = ref object of ContextNodeBase` with `value: T`
  ##    — fresh ref-object subtype per declaration, so distinct
  ##    declarations can never alias each other's storage. Two modules
  ##    each declaring identically-named context vars produce
  ##    same-named slot types; importing both into a third module is
  ##    legal on its own — the collision only surfaces as Nim's
  ##    ordinary ambiguous-identifier error where the unqualified
  ##    reader or binder is actually used, and qualified access still
  ##    resolves each side to its own, genuinely distinct slot type.
  ##    Leave an arm unstarred to keep it module-private and out of
  ##    this concern entirely.
  ## 2. `template name(): T` — reader; returns the current binding for
  ##    this task, or `default` if no binding is in scope. `default`
  ##    is spliced into the reader and re-evaluated on every unbound
  ##    call rather than computed once at declaration time — keep it
  ##    cheap and side-effect-free.
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
      # arm name via `genSym` or processes typed AST. `$node`
      # stringifies both forms; downstream `ident(...)` calls produce
      # fresh `nnkIdent`s for the generated slot type and `withName`,
      # so the emitted public surface uses regular identifiers
      # regardless of how the arm name arrived.
      #
      # Caveat: when arm name arrives as a gensym'd `nnkSym` (e.g.,
      # `genSym(nskVar, "foo")`), `$node` returns the base name
      # ("foo"), and the emitted slot type / reader / binder all get
      # valid Nim identifier names. However, the reader template
      # (which uses `bareName = ident(name)` per the normalization
      # below) is then declared into the macro-call-site scope using
      # the same name as the gensym'd source symbol. Whether that
      # template is reachable from external code depends on whether
      # the gensym leaks out — which it normally doesn't, because
      # gensym'd symbols are scoped to the producing macro. The
      # `withName` binder is always reachable because it's named via
      # `ident("with" & name)` which produces a fresh, exportable
      # identifier independent of the arm-name's syntactic kind.
      # This is by design: the nnkSym path is for advanced macro
      # composition where the caller manages reader access via its
      # own emission.
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
