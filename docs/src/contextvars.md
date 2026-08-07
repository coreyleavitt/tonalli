# Context variables

Context variables provide continuation-local storage: dynamically-scoped
values that follow a logical task through `await` suspensions, callback
registrations and combinators, while concurrent tasks remain isolated from
each other. They serve the same role as Python's `contextvars` module in
`asyncio` — request IDs, authenticated users, tracing spans and similar
"ambient" data that would otherwise have to be threaded through every
procedure signature.

<!-- toc -->

## Usage

```nim
import chronos
import chronos/contextvars

type User = object
  name: string

contextVar:
  var currentUser: User = User(name: "anonymous")

proc audit(action: string) =
  # Reads the innermost binding for the current logical task,
  # or the declared default when no binder is in scope.
  echo currentUser().name, ": ", action

proc handleRequest(user: User) {.async.} =
  withCurrentUser(user):
    await sleepAsync(10.milliseconds)   # binding survives suspension
    audit("query")                      # sees `user`, not the default
```

Each `var name: T = default` arm of a `contextVar` block generates:

- a reader `name(): T` returning the innermost binding, or `default`,
- a snapshot reader `name(ctx: AsyncContext): T` — same semantics,
  read from a captured snapshot instead of the ambient chain (see
  "Inspecting contexts" below),
- a scoped binder `withName(value): body` that binds for the dynamic
  extent of `body` and restores on every exit path (normal, exception,
  `CancelledError`).

An arm may omit `= default` (`var name: T`) to require a binding —
see "Required variables" below.

Bindings nest (innermost wins) and propagate into tasks spawned within the
binder's extent. Two additional primitives, `currentContext()` and
`withContext(ctx, body)`, snapshot and restore the full binding chain for
synchronous-callback boundaries that don't go through `await`.

**Naming caution**: a generated `withName` binder shares ordinary
module scope with everything else chronos exports, and the two can
collide. An arm named `timeout`, for instance, generates `withTimeout`
— the same name as chronos's own `withTimeout` combinator
(`Future[T].withTimeout(Duration): Future[bool]`). This is a compile
error, not just a caution: `contextVar` checks, per arm, whether its
generated `withName` identifier is already declared in the expansion
scope, and fails with a message naming both the arm and the colliding
symbol. The same check catches a duplicate arm name declared twice in
the same module — the second declaration's `withName` is already
declared by the first, so it fails the identical way.

## Semantics notes

The reader re-evaluates the arm's default expression on every unbound
read — the `contextVar` macro splices the default expression's AST
directly into the reader template rather than evaluating it once at
declaration time. This differs from Python's PEP 567, where a
`ContextVar`'s default is fixed at construction. Keep default
expressions cheap and side-effect-free; anything expensive belongs
behind an explicit `withName` binding instead.

## Required variables

An arm may omit its default entirely:

```nim
contextVar:
  var traceId: string    # must-bind: no `= default`
```

This declares a *must-bind* variable — the analog of PEP 567's
default-less `ContextVar`. Reading `traceId()` while no `withTraceId`
binder is in scope raises `UnboundContextVarDefect` instead of falling
back to a value. The Defect's `varName: string` field names the
unbound arm (`"traceId"` here), from both the ambient and the
snapshot reader:

```nim
proc handler() {.async: (raises: []).} =
  # traceId() here would raise UnboundContextVarDefect unless a caller
  # already bound it.
  withTraceId(newTraceId()):
    await process()
```

`UnboundContextVarDefect` is a `Defect`, not a `CatchableError`. That's
deliberate, for two reasons:

- Reading a must-bind variable before it's bound is a contract
  violation — the caller forgot a `withName` somewhere up the call
  chain — not a recoverable runtime condition like a failed network
  call. `Defect` is chronos's (and Nim's) vocabulary for "this is a
  bug," the same category as an out-of-bounds index or a failed
  `doAssert`.
- `Defect`s sit outside Nim's `raises` effect tracking. A must-bind
  reader can therefore be called from an `{.async: (raises: []).}`
  proc — the common case for handler code that doesn't want to widen
  its raises list — without the compiler forcing every caller to
  declare or catch an exception for a condition that, if it occurs at
  all, indicates a bug rather than an expected failure mode.

Everything else about a must-bind arm is identical to a defaulted one:
the binder (`withName`), spawn-time inheritance, propagation across
`await`, and restore-on-every-exit-path all use the exact same
generated code — only the reader's behavior on a miss differs. The
snapshot reader (below) mirrors this: `name(ctx)` raises
`UnboundContextVarDefect` if the arm is unbound in `ctx`.
`dumpContext` is the one exception to "raises like the reader" — see
"Inspecting contexts" below for why introspection never raises.

## Binding multiple variables

There is no combined "bind several at once" form — binding multiple
context variables together is ordinary nested `withName` blocks, one
per variable:

```nim
contextVar:
  var currentUser: User = anonymous
  var requestId: string = ""

proc handleRequest(user: User, reqId: string) {.async.} =
  withCurrentUser(user):
    withRequestId(reqId):
      await sleepAsync(10.milliseconds)
      audit("query")   # sees both currentUser() and requestId()
```

Each `withName` layer adds one `try`/`finally` frame, so the cost scales
with the number of variables bound at a given point, not with the number
of `contextVar` declarations in scope elsewhere. Independent variables
don't interact with each other, so the nesting order between them is
arbitrary — binding `requestId` inside `currentUser` or the other way
around produces the same observable bindings either way.

## The empty context

A default-initialized `AsyncContext` (`var ctx: AsyncContext`, never
assigned from `currentContext()`) is the *empty* context — the same
one every task starts with before any `withName` runs. Running under
it via `withContext` installs no bindings at all: a defaulted arm
reads its own default, exactly as if no binder were ever entered, and
a must-bind arm raises `UnboundContextVarDefect`, same as an unbound
ambient read.

## Bridging independent callbacks

`withName` binds for the dynamic extent of one body inside one logical
task. A resource's independently-registered setup and teardown hooks (an
`onConnect` and a separate `onDisconnect`) are not that shape: two
independently-scheduled callbacks with no `await` or shared call stack
between them are, by construction, not a single logical task, and no
binder can span them. The dispatcher restores the context it captured at
scheduling time around *every* callback invocation (`fireWithContext` in
`chronos/internal/asyncengine.nim`), so nothing one callback binds
survives into a second, separately-scheduled callback — the next callback
observes whatever context it captured at its own registration.

Skipping this pattern is fail-closed, not a leak: an exit hook that
never captured a snapshot simply runs under whatever context was
ambient at its own registration (typically empty), never under
another task's binding.

For that shape, use `currentContext()`/`withContext()` — capture a
snapshot in the enter hook, restore it in the exit hook:

```nim
var connContexts: Table[Connection, AsyncContext]

proc onConnect(conn: Connection) =
  withCurrentUser(conn.authedUser):
    connContexts[conn] = currentContext()   # snapshot, not a push

proc onDisconnect(conn: Connection) =
  withContext(connContexts[conn]):
    audit("session ended")   # sees currentUser() == conn.authedUser
  connContexts.del(conn)
```

`currentContext()` captures the whole binding chain as an immutable
snapshot that outlives the binder that created it; `withContext` runs code
under that snapshot without disturbing the caller's own chain on exit.
Because a snapshot is a value, not a chain mutation, the same snapshot can
be used from `withContext` any number of times, including from multiple
callbacks interleaved on the same dispatcher.

`AsyncContext` values are thread-affine: the chain they reference is
thread-local, garbage-collected memory (see "Migration / compatibility"
below on cross-thread scheduling), so a snapshot captured on one thread
must not be sent to or restored on another — "any number of times" means
any number of callbacks on the capturing thread.

There is deliberately no imperative token API (PEP 567's
`ContextVar.set()`/`Token.reset()` shape): within a single logical task,
`withName` expresses every binding lifecycle, and across independent
callbacks a token could not work anyway — as described above, the
dispatcher's restore-at-fire discipline unwinds any push a callback
leaves behind. `tests/testcontextvarssurface.nim` enforces the
absence of a token API as a compile-time check.

## Inspecting contexts

Three primitives exist purely for debugging and don't participate in the
hot paths at all — they cost nothing unless a program actually calls them.

**Identity.** Two `AsyncContext` snapshots compare equal with `==` iff
they reference the same underlying chain head:

```nim
let a = currentContext()
let b = currentContext()
a == b            # true: no binding changed between the two captures

withCurrentUser(someUser):
  let c = currentContext()
  a == c          # false: `c` was captured inside a new binder
```

This is identity equality (same chain-head pointer), not a
value-by-value comparison of bindings — two snapshots built
independently that happen to carry the same bindings are not `==`.
`hash*(ctx: AsyncContext): Hash` matches the same identity (a
pointer-identity hash), so `AsyncContext` works as a `Table`/`HashSet`
key.

**Snapshot readers.** Every `contextVar` arm generates a second reader
overload alongside the ambient one, under the *same* name as the
ambient reader rather than a differently-spelled accessor (no
`name[]`/`name.get(ctx)` shape): one accessor identity per variable,
with the snapshot passed explicitly when reading a captured context
instead of the ambient one. A subscript or get-style alternative was
considered and rejected for the same reason `withName` isn't spelled
`bind(name, v)`: it would give each arm two unrelated-looking call
forms for what is conceptually a single reader.

```nim
proc name(ctx: AsyncContext): T
```

It reads the arm's binding as recorded in `ctx` — walking `ctx`'s
chain instead of the ambient one — without installing `ctx` the way
`withContext` would. This is the read-only counterpart to
`withContext`: useful when code wants to inspect a captured context
(a request's originating bindings, say, held for later logging)
without switching the current task onto it. Semantics mirror the
ambient reader exactly: a defaulted arm returns its default when
unbound in `ctx`; a must-bind arm raises `UnboundContextVarDefect`.
Export follows the arm's own `*` marker, same as the ambient reader
and binder.

**`dumpContext` / `` `$` ``.** `dumpContext(ctx: AsyncContext): seq[ContextVarEntry]`
enumerates every *starred* `contextVar` arm declared anywhere in the
program — across every module, defaulted or must-bind — as it stands
in `ctx`, sorted by name:

```nim
type ContextVarEntry* = object
  name*: string
  bound*: bool
  value*: string
```

A non-starred arm is never registered, so it never appears here —
module-private means private to introspection too, not just to
readers/binders. See "Implementation" below.

Every registered arm appears exactly once, bound or not. This is a
deliberate choice: the alternative — showing only the arms that
happen to be bound — hides the "what else *could* be here" half of
the picture, which is exactly what a debugger or log dump wants. An
unbound defaulted arm shows `bound: false` and the value its reader
would actually return (the rendered default); an unbound must-bind
arm shows `bound: false` and a fixed `<unbound>` placeholder — calling
`dumpContext` never raises `UnboundContextVarDefect` the way the arm's
own reader would, because introspection has to stay total to be
useful as a debugging tool. A value is rendered via `$` when the arm's
type has one (checked with `when compiles`); otherwise it's shown as a
placeholder in the form `<TypeName>`. A `ref`-typed arm whose value is
nil renders as the literal string `"nil"` without calling `$` at all —
`when compiles($v)` only proves a matching overload exists, not that
it tolerates a nil receiver, and `dumpContext` walks every declared
arm including ones no caller has bound yet.

`` `$`(ctx: AsyncContext): string `` renders the same information as a
single `{name: value, ...}` string, in the same sorted order, for
quick `echo`/logging use. Its format is not a stable, parseable
contract — only `dumpContext`'s structured `seq[ContextVarEntry]` is.

**Cost.** All three are zero-cost in the sense that matters for this
feature: nothing on the reader, binder, capture, or fire hot paths
changed to support them. `==` is one pointer comparison. The snapshot
reader costs exactly what the ambient reader costs (the same chain
walk), just against a caller-supplied chain instead of the ambient
one. `dumpContext` costs one walk of a program-wide registry of
declared arms (built once, at module init, independent of how many
times any variable is bound or read) plus one `$`-render per arm — paid
only when `dumpContext` is actually called.

The registry itself is worth a note on how it stays out of the way:
each `contextVar` arm emits a module-level global — a plain `object`
(not a `ref`), holding the arm's name as a `cstring` and a
`{.nimcall.}` render-proc pointer — linked into a single process-wide
intrusive list at module init. Neither a `cstring` literal nor a
`nimcall` proc pointer is GC-tracked memory, so building this registry
allocates nothing, and — because it's written once, before any second
thread can exist, and never again — reading it from any thread
afterward (as `dumpContext` does) needs no lock. The only allocation
in this whole path is the `seq[ContextVarEntry]`/rendered `string`s
`dumpContext` itself builds, on the calling thread's own heap.

This no-lock argument assumes a static single-binary deployment,
where module init genuinely runs once, on the main thread, before
`createThread`. It does not hold across `dlopen`/shared-library
boundaries: a library loaded after other threads already exist can
run its module init concurrently with readers, and unloading it
leaves dangling registry entries. Neither shape is a chronos use case
today, but embedding chronos in a plugin/shared-library host would
need to revisit this registry's locking.

## Implementation

A context is an immutable, singly-linked chain of slot nodes. Immutability
is compiler-enforced, not conventional: the chain link (`next`) is private
to the internal leaf module `contextnode.nim` and written exactly once, as
a freshly-allocated node is linked ahead of the current head — no code
outside that module (chronos's own included) can rewrite a link through
any named access, whether via the base type, a macro-emitted slot
subtype, or a `cast`. (The one thing Nim cannot hide a field from is
`fieldPairs`/`fields` reflection; deliberately reflecting over chronos
internals is outside the threat model, same as importing
`chronos/internal/*` directly.) Each
`contextVar` declaration emits a fresh `ref object of ContextNodeBase`
subtype holding its value inline; reading walks the current task's chain and
matches the slot with an `of` check. Because each declaration owns its own
slot type, distinct declarations can never alias each other's storage — an
`of` match against one declaration's type can never return another
declaration's value, even if the two share a name. Two modules can each
declare a context var with the same name: importing both into a third
module is legal on its own, and only errors where the unqualified reader or
binder is actually used, as Nim's ordinary ambiguous-identifier error —
not silent misresolution. Qualified access (`moduleA.name()` vs
`moduleB.name()`) still resolves each side to its own, genuinely distinct
slot type. To avoid the collision in the first place, leave an arm
unstarred (`var name: T = default`, no `*`): non-starred arms are
module-private and invisible to other modules entirely — including to
`dumpContext`/`` `$` ``, which only ever see a starred arm's state,
not merely its reader/binder identifiers.

The current chain head lives in a per-thread variable. The dispatcher
propagates it by value through every scheduling site:

- **Capture at scheduling**: constructing a user-facing `AsyncCallback`
  snapshots the current chain head into the callback's `context` field (a
  native `ref` — Nim's memory management owns the lifecycle; there are no
  manual `GC_ref`/`GC_unref` operations to forget at drop sites).
- **Restore at fire**: the dispatcher's callback loop compares the
  callback's captured chain against the chain already installed (an
  identity check on the head pointer). If they already match — the
  common case whenever a program never binds a context variable at
  all, and often the case between consecutive callbacks of the same
  binder — nothing is written: no assignment, no `try/finally`. If
  they differ, the dispatcher installs the callback's captured chain
  for the duration of the invocation and reverts to the prior chain
  afterwards, including on an exception exit, so consecutive callbacks
  each see their own captured context regardless of what the callback
  before them left behind.

Binding is O(1) (push a node); reading is O(chain length), where the chain
only contains the bindings currently in dynamic scope. Code that never binds
a context variable carries a `nil` chain: capture copies one pointer and
lookup is a `nil` check.

## Capture discipline

The obligation this section places on every scheduling-site author: a
context-blind trampoline (`bareCallback`) is sound only when everything
it fires either captured its own context at registration or is itself
context-neutral. `bareCallback` doesn't check this — it just fires with
an empty context — so a bare trampoline that starts firing
context-sensitive code without one of the other two constructors
upstream reintroduces a leak silently.

Every `AsyncCallback` construction site must deliberately pick one of three
constructors defined in `chronos/futures.nim`:

- `capturingCallback(fn, udata)` — for every scheduling site whose callback
  must observe registration-time bindings (`addCallback`, `callSoon`,
  `setTimer`, `addReader`/`addWriter`, `addSignal`/`addProcess`, `callIdle`,
  `closeSocket`/`closeHandle` after-callbacks), whether the callback is
  application code or chronos-internal. Captures the current context.
- `bareCallback(fn, udata)` — for chronos-internal trampolines
  (sentinels, cross-thread queue draining, the low-level per-operation
  IOCP read/write completion trampolines, `internalCallTick`'s
  `CallbackFunc` overloads) where no meaningful registration-time
  context exists. Fires with an empty context.
- `contextCallback(fn, udata, ctx)` — for reconstructing a callback from
  a context value captured *earlier* rather than the ambient one at the
  call site. Windows IOCP completion dispatch (`poll()` in
  `asyncengine.nim`) is the only caller: it fires every completion with
  whatever `CompletionData.context` an upstream arm site
  (`registerWaitable`, a stream server's `start()`) stored via
  `captureContextInto`, nil - reproducing `bareCallback`'s
  empty-context behavior - otherwise.

`internalCallTick` also has an `AsyncCallback`-taking overload
(`internalCallTick(acb: AsyncCallback)`) that simply schedules whatever
`AsyncCallback` the caller already built — the caller picks the
constructor when building that value. Only the convenience `CallbackFunc`
overloads (`internalCallTick(cbproc, data)`) default to `bareCallback`
and are therefore context-blind by design.

Unauthorized *construction* of an `InternalAsyncCallback` is a compile
error, not a convention: `function`/`udata`/`context` are private to
`chronos/futures.nim`, so only `capturingCallback`/`bareCallback`/
`contextCallback` can build a value, and no other module can
read-modify a field after construction (existing readers go through
exported `function()`/`udata()`/`context()` getters). A raw
`AsyncCallback(function: ..., udata: ...)` literal, or a direct field
assignment, anywhere outside `chronos/futures.nim` simply fails to
compile — `tests/testcontextvarsguardrails.nim` asserts this with
`not compiles(...)` checks.

*Which* constructor a given scheduling site calls, however, is not
something the type system can check — the three share a shape, so
picking the wrong one compiles fine. That discipline rests on an
enumerate-and-pin approach instead:
`tests/testcontextvarssurface.nim` and `tests/testcontextvarsguardrails.nim`
enumerate every known construction/capture site and pin its expected
behavior, so a *changed* site shows up as a failing assertion — but a
genuinely *new* scheduling site added without updating those pins would
not be caught by them. Extending the pins is part of adding one.

## Spawn-time inheritance

A task spawned inside a binder (calling an `async` proc, `asyncSpawn`, or
registering a callback) inherits the spawner's binding chain as it existed
at the point of spawning. Because the chain is immutable, later re-binding
in the parent is invisible to the already-spawned child and vice versa —
a child's nested binding never leaks back to the parent.

Slot nodes own their values inline, so a `currentContext()` snapshot (or a
pending callback's captured chain) remains sound after the binder that
created it has exited.

## Migration / compatibility

- The feature is additive: code that never declares a context variable pays
  one pointer field per `AsyncCallback` and a pointer copy per capture.
- Cross-thread scheduling (`callSoon` on another thread's dispatcher via
  `DispatcherHandle`) fires the callback with an *empty* context: the
  origin thread's chain is thread-local, garbage-collected memory and
  cannot be shared. Same-thread scheduling through the same API captures
  normally.
- **Windows IOCP completions carry the registrant's context**: every
  `OVERLAPPED`-based completion (`CompletionData`, the record armed by
  `registerWaitable` and by a stream server's accept machinery) carries
  a `context` field, captured via `captureContextInto` at the site that
  arms the completion, and restored when `poll()` dispatches the fired
  callback — the same registration-time-capture contract as the
  epoll/kqueue paths, just carried on the completion record instead of
  in an `AsyncCallback` built inline. `addProcess2`/`addSignal2`
  (via `registerWaitable`) and a stream server's handler (captured at
  `start()`, not at `createStreamServer()` or per-connection) both
  propagate correctly. `CompletionData.context` is nil - reproducing
  the historical empty-context, fail-closed behavior - for any
  completion whose arm site does not opt in; this remains true, by
  design, for the low-level per-operation read/write completion
  trampolines (they only drive an internal future to completion, and
  that future's own awaiter already carries its own captured context
  from the normal `capturingCallback` path, so there's nothing for those
  trampolines themselves to propagate). The accept loop's `context` is
  captured once, at `start()`, and reused for every connection the
  server ever accepts — it is not re-captured per connection, so a
  caller that binds a large value around `start()` pins it for the
  server's entire lifetime, not just for one `start()` call.

## Performance

The design goal is cost proportional to use: a program that never
declares a context variable should pay a cost indistinguishable, on
every hot path, from a build without the feature at all. This is
measured, not assumed.

**refc** (chronos's most latency-sensitive consumers pin `--mm:refc`
unconditionally) is the headline: `callSoon` schedule+fire — the
hottest path a contextvars-free program pays on every scheduled
callback — measured against a pre-contextvars baseline, with runs
interleaved to cancel out machine noise, lands at 1.04x (bootstrap 95%
CI [0.82, 1.26] — statistically indistinguishable from 1.0x, i.e. no
measurable regression). **orc** lands at 0.99x, likewise noise.

Per-call-class timings, both memory managers, baseline (pre-contextvars)
vs. this feature (ns/call):

| call class    | refc baseline | refc w/ contextvars | orc baseline | orc w/ contextvars |
|----------------|---------------:|----------------------:|---------------:|----------------------:|
| `callSoon`     | 30.8           | 36.8                  | 57.2           | 63.8                  |
| sleep chain    | 860            | 864                   | 1083           | 1054                  |
| create + await | 101.2          | 106.5                 | 127.7          | 124.7                 |

orc's sleep-chain and create/await rows land *below* baseline —
within the same run-to-run noise as the rest of this table, not a
claim that contextvars makes orc faster.

Per-call-class cost, both memory managers, confirmed by inspecting the
generated C at each site rather than inferred from throughput alone:

- leaf callback fire: one thread-local load + one predicted branch.
- continuation resume: the above plus one unconditional save/restore
  pair, required for correctness — a suspended continuation must not
  leak a stale binding into whatever fires next.
- user-callback construction: one thread-local load + one predicted
  branch; barrier-free on refc, and on orc the context copy is skipped
  entirely when no binder is live.
- registering a callback on a heap-allocated future (e.g. a cancel
  callback): one write-barrier call per `ref` field under refc, paid
  once, at the point ownership transfers into the heap field.

Struct cost: `sizeof(AsyncCallback)` grows by one pointer field (8 B);
a pending future's two embedded callbacks add 16 B combined.

A related, separately-motivated fix ships alongside this feature: the
dispatcher's internal callback queues previously used `std/deques`,
whose `popFirst` returns its element by value — a pre-existing cost
(present before contextvars, on the queue's original single `ref`
field) that contextvars' second `ref` field doubled. The dispatcher
now uses a small purpose-built queue (`chronos/internal/callbackqueue.nim`)
whose dequeue is barrier-free on the copy-out; this restores
queue-transport cost per hop to parity with what the pre-contextvars
codebase already paid on its one field, and accounts for the majority
of the improvement in the refc headline number above.

## Test plan

- `tests/testcontextvars.nim` — synchronous semantics: declaration,
  defaults, nesting/shadowing, restore on all exit paths, and the binder
  contract (push/pop balance on every exit path); `AsyncContext` identity
  (`==`, `hash`, table-key usability); snapshot readers (bound-in-snapshot,
  outer-vs-inner-binding, defaulted-unbound); must-bind arms (unbound
  raise with `varName` set, bound read, LIFO restore, snapshot-reader
  raise); `dumpContext`/`` `$` `` (bound, defaulted-unbound,
  must-bind-unbound, a non-`$`-able type's placeholder path, a
  `ref`-typed arm's nil-safe render, and sorted-by-name ordering); the
  empty (default/nil) `AsyncContext`'s no-bindings behavior under
  `withContext`.
- `tests/testcontextvarsasync.nim` — async propagation (isolation across
  interleaved tasks, survival across sequential awaits, exception and
  cancellation paths, spawn-time inheritance), per-scheduling-site
  capture coverage (`callSoon`, `setTimer`/`sleepAsync`, `callIdle`,
  `addReader`, `race`/`allFutures`, `closeSocket`/`closeHandle`), the
  bridging pattern from "Bridging independent callbacks" above:
  `currentContext()`/`withContext()` carries a binding from an enter hook
  into a separately-scheduled exit hook, and a must-bind arm's binding
  propagating across `await` exactly like a defaulted one.
- `tests/testcontextvarsguardrails.nim` — compile-time drift detection:
  the private-field/constructor-only enforcement, the native-`ref` context
  field, callback layout, the introspection registry's
  `.registered`/`.next` fields staying private to `contextvars_impl.nim`,
  and the `withName` collision check (a colliding arm name, and a
  same-module duplicate arm, both fail to compile).
- `tests/testcontextvarssurface.nim` — verifies `import chronos`
  plus `import chronos/contextvars` expose only the intended public API
  (`contextVar`, `AsyncContext`, `` `==` ``, `hash`, `currentContext`,
  `withContext`, `dumpContext`, `ContextVarEntry`, `` `$` ``,
  `UnboundContextVarDefect`) and none of the dispatcher/registry
  internals (`ContextNodeBase`, `currentAsyncContext`,
  `capturingCallback`/`bareCallback`, `context`,
  `contextLookup`/`contextLookupSnapshot`/`contextBindSlot`,
  `contextFind`/`contextFindSnapshot`, `ContextVarRegistration`,
  `ContextVarRenderProc`, `registerContextVar`, `contextVarRegistry`);
  also pins the deliberate absence of an imperative token API
  (`AsyncContextToken`), that a must-bind arm (`var name: T`, no
  default) is legal syntax, and — on the `--os:windows` leg —
  that `CompletionData.context` is not reachable either.
- `tests/testcontextvarsexport.nim` + `tests/contextvarsexportfixture.nim`
  — cross-module export-marker semantics: a starred arm's reader,
  snapshot reader, and binder are all reachable from an importing
  module; a non-starred arm's are not (including from `dumpContext`,
  not just by name); no arm generates an imperative `setName` binder.
- `tests/testcontextvarsbalance.nim` — the suite-final binder-balance
  check (`chainBalance`/`chainLen`), split out of `testutils.nim` so it
  runs on every engine, including `poll` (see `tests/testall.nim`).
