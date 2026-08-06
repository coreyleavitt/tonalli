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
- a scoped binder `withName(value): body` that binds for the dynamic
  extent of `body` and restores on every exit path (normal, exception,
  `CancelledError`).

Bindings nest (innermost wins) and propagate into tasks spawned within the
binder's extent. Two additional primitives, `currentContext()` and
`withContext(ctx, body)`, snapshot and restore the full binding chain for
synchronous-callback boundaries that don't go through `await`.

## Semantics notes

The reader re-evaluates the arm's default expression on every unbound
read — the `contextVar` macro splices the default expression's AST
directly into the reader template rather than evaluating it once at
declaration time. This differs from Python's PEP 567, where a
`ContextVar`'s default is fixed at construction. Keep default
expressions cheap and side-effect-free; anything expensive belongs
behind an explicit `withName` binding instead.

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
module-private and invisible to other modules entirely.

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

Every `AsyncCallback` construction site must deliberately pick one of two
constructors defined in `chronos/futures.nim`:

- `userCallback(fn, udata)` — for every site that schedules *user* code
  (`addCallback`, `callSoon`, `setTimer`, `addReader`/`addWriter`,
  `addSignal`/`addProcess`, `callIdle`, `closeSocket`/`closeHandle`
  after-callbacks). Captures the current context.
- `internalCallback(fn, udata)` — for chronos-internal trampolines (IOCP
  completion repackaging, sentinels, cross-thread queue draining,
  `internalCallTick`'s `CallbackFunc` overloads) where no meaningful
  registration-time context exists. Fires with an empty context.

`internalCallTick` also has an `AsyncCallback`-taking overload
(`internalCallTick(acb: AsyncCallback)`) that simply schedules whatever
`AsyncCallback` the caller already built — the caller picks `userCallback`
or `internalCallback` when constructing that value. Only the convenience
`CallbackFunc` overloads (`internalCallTick(cbproc, data)`) default to
`internalCallback` and are therefore context-blind by design.

This is enforced by the type system, not convention: `InternalAsyncCallback`'s
`function`/`udata`/`context` fields are private to `chronos/futures.nim`, so
only `userCallback`/`internalCallback` can construct a value, and no other
module can read-modify a field after construction (existing readers go
through exported `function()`/`udata()`/`context()` getters). A raw
`AsyncCallback(function: ..., udata: ...)` literal, or a direct field
assignment, anywhere outside `chronos/futures.nim` simply fails to compile —
`tests/testcontextvarsguardrails.nim` asserts this with `not compiles(...)`
checks, so drift is a compile error, not something a grep sweep has to catch.

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
- **Windows limitation**: callbacks that complete through the IOCP
  waitable path (`addProcess2`/`addSignal2` on Windows) fire with an
  *empty* context rather than the registrant's: `CompletionData.cb` is
  registered without capturing the caller's context. This is a
  deliberate, documented limitation, not pending work — it is
  fail-closed, so another task's bindings can never leak in. The
  epoll/kqueue paths propagate correctly.

## Performance

The design goal is cost proportional to use: a program that never
declares a context variable should pay a cost indistinguishable, on
every hot path, from a build without the feature at all. This is
measured, not assumed.

**refc** (chronos's most latency-sensitive consumers pin `--mm:refc`
unconditionally) is the headline: `callSoon` schedule+fire — the
hottest path a contextvars-free program pays on every scheduled
callback — measured against a pre-contextvars baseline, with runs
interleaved to cancel out machine noise, lands at 1.01x-1.11x, inside
ordinary run-to-run noise. **orc** was within noise from the first
measurement and stays there (~1.10x).

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
  contract (push/pop balance on every exit path).
- `tests/testcontextvarsasync.nim` — async propagation (isolation across
  interleaved tasks, survival across sequential awaits, exception and
  cancellation paths, spawn-time inheritance), per-scheduling-site
  capture coverage (`callSoon`, `setTimer`/`sleepAsync`, `callIdle`,
  `addReader`, `race`/`allFutures`, `closeSocket`/`closeHandle`), and the
  bridging pattern from "Bridging independent callbacks" above:
  `currentContext()`/`withContext()` carries a binding from an enter hook
  into a separately-scheduled exit hook.
- `tests/testcontextvarsguardrails.nim` — compile-time drift detection:
  the private-field/constructor-only enforcement, the native-`ref` context
  field, and callback layout.
- `tests/testcontextvarssurface.nim` — verifies `import chronos`
  plus `import chronos/contextvars` expose only the intended public API
  (`contextVar`, `AsyncContext`, `currentContext`, `withContext`) and
  none of the dispatcher internals (`ContextNodeBase`,
  `currentAsyncContext`, `userCallback`/`internalCallback`, `context`,
  `contextLookup`/`contextBindSlot`); also pins the deliberate absence
  of an imperative token API (`AsyncContextToken`).
- `tests/testcontextvarsexport.nim` + `tests/contextvarshelper.nim`
  — cross-module export-marker semantics: a starred arm's reader and
  binder are reachable from an importing module; a non-starred arm's are
  not, and no arm generates an imperative `setName` binder.
