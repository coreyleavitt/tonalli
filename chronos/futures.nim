#
#                     Chronos
#
#  (c) Copyright 2015 Dominik Picheta
#  (c) Copyright 2018-2025 Status Research & Development GmbH
#
#                Licensed under either of
#    Apache License, version 2.0, (LICENSE-APACHEv2)
#                MIT license (LICENSE-MIT)

{.push raises: [].}

import ./[config, srcloc]
import ./internal/contextnode

export srcloc

when chronosStackTrace:
  type StackTrace = string

type
  LocationKind* {.pure.} = enum
    Create
    Finish

  # TODO forbid nested poll
  # TODO https://github.com/nim-lang/Nim/issues/25976
  CallbackFunc* = proc (arg: pointer) {.gcsafe, raises: [].}

  # Internal type, not part of API
  InternalAsyncCallback* = object
    function: CallbackFunc
    udata: pointer
    context: ContextNodeBase
      ## Continuation-local context captured at scheduling time. A
      ## native `ref` field: Nim's MM (refc/orc/arc) refcounts capture
      ## at construction and release on every drop pattern (assignment
      ## overwrite, seq element removal, future GC'd with pending
      ## callbacks, deque popFirst) without manual `GC_ref`/`GC_unref`.
      ## Nil for callbacks scheduled outside any binding, and for
      ## chronos-internal trampolines that don't fire user code.
      ##
      ## `SentinelCallback` is a zero-arg `template` (not `const` —
      ## Nim 2.x rejects `const` of an object containing a `ref` field,
      ## and a module-level `let` is gcsafe-inaccessible from `poll`).
      ## `isSentinel` uses full struct equality; the comparison is
      ## unambiguous because `sentinelCallbackImpl` is a private,
      ## unexported proc that no legitimate caller can place in an
      ## AsyncCallback.
      ##
      ## `function`/`udata`/`context` are private to this module —
      ## only `userCallback`/`internalCallback` below can construct an
      ## `InternalAsyncCallback`, and no other module can mutate the
      ## fields after the fact. This is the compile-time replacement
      ## for the capture-coverage discipline (every scheduling site
      ## must pick a constructor); see the getters and constructors
      ## further down and docs/src/contextvars.md §Capture discipline.

  # RFC 0001 D5: `internalCancelcb` doesn't need `InternalAsyncCallback`'s
  # full three-field shape. Every construction site (`newCancelCallback`
  # below, and the no-capture site in `internalInitFutureBase`) stores
  # exactly `cast[pointer](future)` for the future the field lives on,
  # and the fire site (`fireCancelCallback` in `asyncfutures.nim`)
  # already has `future` in scope to derive that pointer itself — so
  # `udata` is provably redundant here. `InternalAsyncCallback` keeps
  # all three fields unchanged: it's shared with `internalCallback`/
  # `internalCallbacks`, whose `udata` is a genuinely arbitrary caller
  # pointer.
  InternalCancelCallback* = object
    function: CallbackFunc
    context: ContextNodeBase
      ## Same capture/lifetime discipline as `InternalAsyncCallback.
      ## context` above - a native `ref` field, MM-managed, nil for
      ## cancel callbacks registered outside any binding.
      ##
      ## `function`/`context` are private to this module - only
      ## `newCancelCallback` (below) and the no-capture construction in
      ## `internalInitFutureBase` can build an `InternalCancelCallback`,
      ## and no other module can mutate the fields after the fact.

  FutureState* {.pure.} = enum
    Pending, Completed, Cancelled, Failed

  FutureFlag* {.pure.} = enum
    OwnCancelSchedule
      ## When OwnCancelSchedule is set, the owner of the future is responsible
      ## for implementing cancellation in one of 3 ways:
      ##
      ## * ensure that cancellation requests never reach the future by means of
      ##   not exposing it to user code, `await` and `tryCancel`
      ## * set `cancelCallback` to `nil` to stop cancellation propagation - this
      ##   is appropriate when it is expected that the future will be completed
      ##   in a regular way "soon"
      ## * set `cancelCallback` to a handler that implements cancellation in an
      ##   operation-specific way
      ##
      ## If `cancelCallback` is not set and the future gets cancelled, a
      ## `Defect` will be raised.

  FutureFlags* = set[FutureFlag]

  InternalFutureBase* = object of RootObj
    # Internal untyped future representation - the fields are not part of the
    # public API and neither is `InternalFutureBase`, ie the inheritance
    # structure may change in the future (haha)

    internalLocation*: array[LocationKind, ptr SrcLoc]
    internalCallback*: InternalAsyncCallback
      ## The vast majority of futures track a single callback only (the one
      ## installed by `await`) - to avoid allocating a seq (which involves
      ## making a separate allocation with space for several callbacks), we keep
      ## a spot in each future for that first one - the seq below will stay
      ## empty until a second callback is added
    internalCallbacks*: seq[InternalAsyncCallback]
    internalCancelcb*: InternalCancelCallback
    internalChild*: FutureBase
    internalState*: FutureState
    internalFlags*: FutureFlags
    internalError*: ref CatchableError ## Stored exception
    internalClosure*: iterator(f: FutureBase): FutureBase {.raises: [], gcsafe.}

    when chronosFutureId:
      internalId*: uint

    when chronosStackTrace:
      internalErrorStackTrace*: StackTrace
      internalStackTrace*: StackTrace ## For debugging purposes only.

    when chronosFutureTracking:
      internalNext*: FutureBase
      internalPrev*: FutureBase

  FutureBase* = ref object of InternalFutureBase
    ## Untyped Future

  Future*[T] = ref object of FutureBase ## Typed future.
    when T isnot void:
      internalValue*: T ## Stored value

  FutureDefect* = object of Defect
    cause*: FutureBase

  FutureError* = object of CatchableError
    future*: FutureBase

  CancelledError* = object of FutureError
    ## Exception raised when accessing the value of a cancelled future

func raiseFutureDefect(msg: static string, fut: FutureBase) {.
    noinline, noreturn.} =
  raise (ref FutureDefect)(msg: msg, cause: fut)

# --- InternalAsyncCallback: read-only accessors ------------------------------
#
# `function`/`udata`/`context` are private (see the type above). UFCS
# makes `callable.function` / `.udata` / `.context` reads compile
# unchanged at every existing call site.

func function*(acb: InternalAsyncCallback): CallbackFunc {.inline.} =
  acb.function

func udata*(acb: InternalAsyncCallback): pointer {.inline.} =
  acb.udata

func context*(acb: InternalAsyncCallback): ContextNodeBase {.inline.} =
  acb.context

# --- InternalCancelCallback: read-only accessors -----------------------------
#
# `function`/`context` are private (see the type above, defined beside
# `InternalAsyncCallback`). UFCS makes `callable.function` / `.context`
# reads compile the same way as `InternalAsyncCallback`'s.

func function*(acb: InternalCancelCallback): CallbackFunc {.inline.} =
  acb.function

func context*(acb: InternalCancelCallback): ContextNodeBase {.inline.} =
  acb.context

# --- Continuation-local context: dispatcher-facing primitives ---------------
#
# `currentAsyncContext` and the two-constructor split live here (rather
# than `chronos/internal/contextvars_impl.nim`) because they construct
# `InternalAsyncCallback` values directly and need access to its
# private fields — same-module access is the only way in. `contextvars_
# impl.nim` and `chronos/internal/asyncengine.nim`/`asyncfutures.nim`
# use them via plain `import ../futures`; `asyncengine.nim`'s `export
# futures` explicitly excludes these names so they don't leak
# through `import chronos`. See docs/src/contextvars.md §Capture
# discipline.
#
# `withRestoredContext`/`pinContext` below are placed here for a
# different reason: `ContextNodeBase` is deliberately unnameable outside
# modules that import `contextnode.nim` directly (a pinned security
# property, see `testcontextvarssurface.nim`), and `asyncengine.nim`
# reaches the type only by inference — a typed `newCtx: ContextNodeBase`
# parameter does not compile there. They belong beside their partner
# `currentAsyncContext` regardless; see docs/src/contextvars.md §Capture
# discipline.

var currentAsyncContext* {.threadvar.}: ContextNodeBase
  ## Per-thread head of the binding chain. Chronos is single-thread-
  ## per-dispatcher, so this is effectively per-dispatcher.

template captureContextInto*(dest: var ContextNodeBase) =
  ## D8's construction discipline: capture the ambient context into a
  ## field of a FRESHLY DECLARED local — never an object literal, never
  ## `result`. The guard costs one predicted branch; on orc it
  ## additionally elides the ref-copy call outright when no binder is
  ## live (cost proportional to use). Do not "simplify" callers back
  ## to object literals: that reintroduces refc's reset-then-assign
  ## barrier doubling that S8's abort gate caught (RFC 0001 D8).
  if not isNil(currentAsyncContext):
    dest = currentAsyncContext

template userCallback*(fn: CallbackFunc, ud: pointer = nil): InternalAsyncCallback =
  ## Construct an AsyncCallback that fires user-supplied code. Captures
  ## the current continuation-local context at construction so the
  ## callback fires under the same `contextVar` bindings the registrant
  ## had at registration.
  ##
  ## Use at every site that schedules user code: `addCallback`,
  ## `callSoon(cb, data)`, `setTimer`, `addReader`/`addWriter`/
  ## `addSignal`/`addProcess`, `callIdle`,
  ## `closeSocket(fd, aftercb)`/`closeHandle(fd, aftercb)`.
  ##
  ## NOT for `internalCallTick`'s `CallbackFunc` overloads or other
  ## chronos-internal trampolines (sentinel handlers, `idleAsync`'s
  ## completion stub, IOCP completion repackaging) — those use
  ## `internalCallback` to avoid needlessly capturing the caller's
  ## context. The downstream user-visible callbacks (awaiters on the
  ## future the trampoline completes) carry their own captured context
  ## via their original `addCallback` site.
  ##
  ## Deliberate exception: `internalContinue` (the iterator-pump
  ## resume trampoline scheduled by `futureContinue`) goes through
  ## `addCallback` and therefore `userCallback`. The capture is
  ## load-bearing — it's what carries the iterator's per-yield
  ## context across suspension. See docs §Spawn-time inheritance.
  ##
  ## Lifetime: `context` is a native `ref` field. Nim's MM refcounts
  ## the captured chain at assignment and releases it on every drop
  ## pattern (assignment overwrite, seq element removal, future GC'd
  ## with pending callbacks, deque popFirst) — no manual `GC_ref` /
  ## `GC_unref` or `releaseCallbackContext` calls needed.
  ##
  ## Template (not proc), constructing into a fresh local in the
  ## caller's frame — RFC 0001 D8: a `proc` returning this by value
  ## forces refc's reset-then-assign copy-out through the hidden return
  ## slot (four write-barrier calls per construction, two of them
  ## provably-dead nil-over-nil work, paid on every callback whether or
  ## not any `contextVar` is ever bound). The fresh local plus
  ## `captureContextInto`'s guard restores refc's original zero-barrier
  ## construction and, on orc, elides the context ref-copy call
  ## entirely in the unbound case.
  ##
  ## Param is named `ud` (not `udata`) for the same reason as
  ## `internalCallback` below: template substitution rewrites every
  ## matching identifier in the body, including the field name after a
  ## dot (`acb.udata`) — with a `udata` param that would try to
  ## substitute the field access itself. See `internalCallback`'s
  ## comment for the full explanation.
  var acb: InternalAsyncCallback
  acb.function = fn
  acb.udata = ud
  captureContextInto(acb.context)
  acb

template internalCallback*(fn: CallbackFunc, ud: pointer = nil): InternalAsyncCallback =
  ## Construct an AsyncCallback that fires chronos-internal scaffolding
  ## (IOCP completion repackaging, idle-loop sentinels, fd-readiness
  ## trampolines that just complete user futures). No context capture
  ## — the chronos-internal code being scheduled doesn't read
  ## contextVars, and any user-visible callbacks downstream (the
  ## awaiters on whatever future the trampoline completes) carry their
  ## own captured context via `userCallback` at their original
  ## `addCallback`/`callSoon` site.
  ##
  ## Template (not proc) so it composes into other templates
  ## without a gcsafe issue — chiefly `SentinelCallback` in
  ## `asyncengine.nim`, which has to be a template itself (Nim 2.x
  ## rejects `const` of an object containing a `ref` field, and a
  ## module-level `let` is gcsafe-inaccessible from `poll`).
  ##
  ## Param is named `ud` (not `udata`) because Nim's template
  ## substitution applies to identifiers anywhere in the body — including
  ## the LHS of `field: value` in object constructors. With a `udata`
  ## param, the body's `udata: ud` would expand to `<value>: <value>`
  ## (both sides substituted), failing with "identifier expected" —
  ## e.g. when this template is called as
  ## `internalCallback(sentinelImpl, nil)` from `SentinelCallback`.
  InternalAsyncCallback(function: fn, udata: ud, context: nil)

template newCancelCallback*(fn: CallbackFunc): InternalCancelCallback =
  ## Construct the value stored in `internalCancelcb`. Captures the
  ## current continuation-local context at construction — `userCallback`'s
  ## discipline, sized to what cancel callbacks actually need: no `udata`
  ## field, since the fire site (`fireCancelCallback` in
  ## `asyncfutures.nim`) already has the owning future in scope and
  ## derives `cast[pointer](future)` itself instead of storing a
  ## redundant copy (RFC 0001 D5).
  ##
  ## Template (not proc), same construction discipline as `userCallback`
  ## above (RFC 0001 D8): a fresh local in the caller's frame plus
  ## `captureContextInto`'s guard, instead of a by-value proc whose
  ## return-slot copy-out doubles refc's write-barrier count. No `ud`
  ## rename needed here — `InternalCancelCallback` has no `udata` field
  ## for the substitution gotcha to collide with.
  var cb: InternalCancelCallback
  cb.function = fn
  captureContextInto(cb.context)
  cb

template withRestoredContext*(newCtx: ContextNodeBase, body: untyped) =
  ## Context switch with identity fast path. Sound only when `body`
  ## cannot dangle the binder chain across a suspend — i.e. body is not
  ## a continuation pump, or the pump's entry re-pins (`pinContext`).
  let chronosCtxPrev = currentAsyncContext        # one TLS read
  if newCtx == chronosCtxPrev:                    # identity ⇒ no writes,
    body                                          # no try/finally
    when defined(chronosDebug):
      doAssert currentAsyncContext == newCtx,
        "identity arm violated: a pump body went through " &
        "withRestoredContext without its own pinContext"
  else:
    currentAsyncContext = newCtx
    try: body
    finally: currentAsyncContext = chronosCtxPrev

template pinContext*(body: untyped) =
  ## Unconditional entry/exit guard ("the pin"), no fast path ever — for
  ## bodies that may suspend mid-binder (continuation pumps).
  let chronosCtxPrev = currentAsyncContext
  try: body
  finally: currentAsyncContext = chronosCtxPrev

when chronosFutureId:
  var currentID* {.threadvar.}: uint
  template id*(fut: FutureBase): uint = fut.internalId
else:
  template id*(fut: FutureBase): uint =
    cast[uint](addr fut[])

when chronosFutureTracking:
  type
    FutureList* = object
      head*: FutureBase
      tail*: FutureBase
      count*: uint

  var futureList* {.threadvar.}: FutureList

# Internal utilities - these are not part of the stable API
proc internalInitFutureBase*(fut: FutureBase, loc: ptr SrcLoc,
                             state: FutureState, flags: FutureFlags) =
  fut.internalState = state
  fut.internalLocation[LocationKind.Create] = loc
  fut.internalFlags = flags
  if FutureFlag.OwnCancelSchedule in flags:
    # Owners must replace `cancelCallback` with `nil` if they want to ignore
    # cancellations
    proc raiseNonCancellable(_: pointer) =
      raiseAssert "Cancellation request for non-cancellable future"
    # No-capture construction, same-module and direct (RFC 0001 D5):
    # not a second named constructor next to `newCancelCallback` — a
    # `Cancel`-infixed pair here would be the name-based-split footgun
    # rejected for `userCallback`/`internalCallback`'s composition (D3).
    # RFC 0001 D8: targeted field write, not a whole-struct literal —
    # `fut` is a just-allocated, provably-fresh `Future[T]()` at every
    # call site (traced in round 3), so `context` is already nil from
    # the allocator's zero-fill; writing it again would only reinstate
    # the reset-then-assign barrier doubling D8 removes elsewhere.
    fut.internalCancelcb.function = raiseNonCancellable

  if state != FutureState.Pending:
    fut.internalLocation[LocationKind.Finish] = loc

  when chronosFutureId:
    currentID.inc()
    fut.internalId = currentID

  when chronosStackTrace:
    fut.internalStackTrace = getStackTrace()

  when chronosFutureTracking:
    if state == FutureState.Pending:
      fut.internalNext = nil
      fut.internalPrev = futureList.tail
      if not(isNil(futureList.tail)):
        futureList.tail.internalNext = fut
      futureList.tail = fut
      if isNil(futureList.head):
        futureList.head = fut
      futureList.count.inc()

# Public API
template init*[T](F: type Future[T], fromProc: static[string] = ""): Future[T] =
  ## Creates a new pending future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  let res = Future[T]()
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Pending, {})
  res

template init*[T](F: type Future[T], fromProc: static[string] = "",
                  flags: static[FutureFlags]): Future[T] =
  ## Creates a new pending future.
  ##
  ## Specifying ``fromProc``, which is a string specifying the name of the proc
  ## that this future belongs to, is a good habit as it helps with debugging.
  let res = Future[T]()
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Pending,
                         flags)
  res

template completed*(
    F: type Future, fromProc: static[string] = ""): Future[void] =
  ## Create a new completed future
  let res = Future[void]()
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Completed,
                         {})
  res

template completed*[T: not void](
    F: type Future, valueParam: T, fromProc: static[string] = ""): Future[T] =
  ## Create a new completed future
  let res = Future[T](internalValue: valueParam)
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Completed,
                         {})
  res

template failed*[T](
    F: type Future[T], errorParam: ref CatchableError,
    fromProc: static[string] = ""): Future[T] =
  ## Create a new failed future
  let res = Future[T](internalError: errorParam)
  internalInitFutureBase(res, getSrcLocation(fromProc), FutureState.Failed, {})
  when chronosStackTrace:
    res.internalErrorStackTrace =
      if getStackTrace(res.error) == "":
        getStackTrace()
      else:
        getStackTrace(res.error)
  res

func state*(future: FutureBase): FutureState =
  future.internalState

func flags*(future: FutureBase): FutureFlags =
  future.internalFlags

func finished*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` has finished, i.e. ``future`` state changed
  ## from state ``Pending`` to one of the states (``Finished``, ``Cancelled``,
  ## ``Failed``).
  future.state != FutureState.Pending

func cancelled*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` has cancelled.
  future.state == FutureState.Cancelled

func failed*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` finished with an error.
  future.state == FutureState.Failed

func completed*(future: FutureBase): bool {.inline.} =
  ## Determines whether ``future`` finished with a value.
  future.state == FutureState.Completed

func location*(future: FutureBase): array[LocationKind, ptr SrcLoc] =
  future.internalLocation

func value*[T: not void](future: Future[T]): lent T =
  ## Return the value in a completed future - raises Defect when
  ## `fut.completed()` is `false`.
  ##
  ## See `read` for a version that raises a catchable error when future
  ## has not completed.
  when chronosStrictFutureAccess:
    if not future.completed():
      raiseFutureDefect("Future not completed while accessing value", future)

  future.internalValue

func value*(future: Future[void]) =
  ## Return the value in a completed future - raises Defect when
  ## `fut.completed()` is `false`.
  ##
  ## See `read` for a version that raises a catchable error when future
  ## has not completed.
  when chronosStrictFutureAccess:
    if not future.completed():
      raiseFutureDefect("Future not completed while accessing value", future)

func error*(future: FutureBase): ref CatchableError =
  ## Return the error of `future`, or `nil` if future did not fail.
  ##
  ## See `readError` for a version that raises a catchable error when the
  ## future has not failed.
  when chronosStrictFutureAccess:
    if not future.failed() and not future.cancelled():
      raiseFutureDefect(
        "Future not failed/cancelled while accessing error", future)

  future.internalError

when chronosFutureTracking:
  func next*(fut: FutureBase): FutureBase = fut.internalNext
  func prev*(fut: FutureBase): FutureBase = fut.internalPrev

when chronosStackTrace:
  func errorStackTrace*(fut: FutureBase): StackTrace = fut.internalErrorStackTrace
  func stackTrace*(fut: FutureBase): StackTrace = fut.internalStackTrace
