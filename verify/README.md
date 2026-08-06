# verify/ — fork-only D9 verification harness (RFC 0001 S9, S11)

**This directory is never part of the upstream series.** It is tracked on
`worktree-contextvars-rebase` (and its `feat/contextvars` mirror in this
repo) but deliberately **never named in the fold's whole-file allow-list**
(RFC 0001 §5) — an unnamed directory cannot leak into `feat/contextvars`'s
folded commits or any downstream pin. Checking out `feat/contextvars`
elsewhere (a clone, a downstream consumer's vendored copy) will not contain
this directory. That is expected, not a loss: `verify/` exists to give
*this* repository confidence in D9's design before S10 spends implementation
and matrix cycles on it, not to ship.

Hard segregation rules (from RFC 0001 §3 D9-V, enforced by construction):

- `chronos.nimble` gains no dependency and no task from this directory —
  the only edit is a defensive `skipDirs` addition (`"verify"`, alongside
  the pre-existing `"tests"`).
- No CI workflow references this directory. There is none, anywhere, for
  it — manual/local runs only, documented below.
- Nothing under `chronos/`, `tests/`, `benchmarks/`, or `docs/` imports
  `proptest` or `z3`. The only import direction that ever crosses the
  `verify/` boundary is `verify/` importing FROM `chronos/`
  (`callbackqueue_model.nim` imports `chronos/config` for the
  `chronosSink`/`chronosMoveSink` templates) — never the reverse.
- Wiring (`nim.cfg`) is three pinned `--path:` lines to sibling checkouts,
  resolved by absolute filesystem path — never nimble, never milpa.

## What this verifies

RFC 0001 D9 specifies a move-based, seq-backed `CallbackQueue[T]` to replace
`std/deques` in the three dispatcher queues (§3 D9). Before S10 spends a
full implementation + 6-leg matrix cycle on that shape, S9's job is to
machine-check the design *before* the code exists: an abstract
`CallbackQueue[GhostItem]` implementing D9's exact protocol (five entry
points, monotonic head/tail, `copyMem`+`zeroMem` growth, template-fused
dequeue, the five index primitives with their `doAssert` invariants), proved
with two independent techniques:

- **Layer 1 (symex / Z3)** — totality and safety of the five index
  primitives: no reachable `doAssert` violation, over as much of the int
  domain as is physically meaningful.
- **Layer 2 (bmcCheck)** — exhaustive breadth-first plan sweep over the real
  `CallbackQueue[GhostItem]` (real `addLast`/`addFirst`/`popFirst`/growth
  code runs on every step), checking a refcount-conservation ghost-ownership
  ledger layered around it.

Layers 3–5 (bisim vs `std/deques`, coverage-guided fuzz + GC stress,
mutation scoring) are S11's job, against the real implementation now that
S10 has shipped it (`db43cff`) — see the S11 sections below.

**This slice made zero changes to chronos library code.** `chronos/internal/
callbackqueue.nim` does not exist yet; everything under `verify/` is a
fresh, from-scratch mirror of D9's specified shapes, built for exactly this
verification and nothing else.

## Layout

| File | Role |
|---|---|
| `primitives.nim` | The five index primitives (`capMask`, `slotIndex`, `queueLen`, `isFull`, `growTargetCap`), mirroring the validated S9.0 spike (`spike/s9.0-callbackqueue`, `ad569a3`) with two documented, load-bearing deviations (see Findings below). |
| `callbackqueue_model.nim` | The generic `CallbackQueue[T]` (all five real entry points + growth), plus `GhostItem` and a second dequeue template, `popFirstRejected`, implementing the round-4 REJECTED `copyMem`-to-stack-local shape for layer 2 to falsify against. |
| `symex_checks.nim` | Layer 1: six `symexFind(..., tAssertionViolation())` proofs. |
| `bmc_ghost.nim` | Layer 2: six `bmcCheck` runs (two ownership shapes × three invariants) over a ghost refcount ledger. |
| `drift_check.nim` | S11: cheap textual drift check between `primitives.nim`/`callbackqueue_model.nim` (S9's mirrors) and the real, shipped `chronos/internal/callbackqueue.nim` — see "Why layers 1-2 still use mirrors" below. |
| `bisim_check.nim` | S11 layer 3: bisimulation (`bisimulationCheck`) of the REAL `CallbackQueue[int]` vs a `std/deques[int]` reference, both MMs. |
| `fuzz_leak.nim` | S11 layer 4: coverage-guided (IR-mutation) fuzz over random op sequences against the REAL `CallbackQueue[LeakItem]` (`ref`-typed elements), with `GC_fullCollect`/`getOccupiedMem` leak accounting and a dedicated Defect-unwind check, both MMs. |
| `mutants/*.patch` | S11 layer 5: one unified diff per systematic mutant applied to `chronos/internal/callbackqueue.nim` during mutation testing — applied, checked, and reverted mechanically; never left in the tree (see the Layer 5 section below for the kill matrix). |
| `nim.cfg` | The three sibling `--path:` lines (`proptest`, `nim-z3`, `softlink`) + one `chronos/` path for `config.nim` and (S11) the real `chronos/internal/callbackqueue.nim`. |
| `Containerfile` | Derived, throwaway image (`FROM ghcr.io/coreyleavitt/nim:2.2.10`); never modifies the shared base. |
| `run.sh` | `verify/run.sh <symex\|bmc\|drift\|bisim\|fuzz\|all>` — the only supported entry point. `bisim`/`fuzz` are MM-sensitive: select via `MM=refc\|orc` (default `refc`). |
| `bench_crosscommit.nim` | Cross-commit benchmark harness: imports plain `chronos` only, so it compiles unmodified against both a base checkout (`b71392a`) and any commit in this series (`build/base` protocol — see the file's own header for the full interleaved-trial procedure). Relocated here from `benchmarks/` because it requires a second checkout to compare against and is fork-only review methodology, not an upstream-shippable benchmark. |

## Build and run

Build the derived image (once; rebuild only if `Containerfile` changes):

```sh
cd /home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase
podman build -t localhost/chronos-verify:latest -f verify/Containerfile verify
```

Run both layers. `/home/corey/projects/nim/libs` is bind-mounted at the
*same* absolute path inside the container so `nim.cfg`'s `--path:` lines
resolve identically in and out of the container — this single mount covers
`proptest`, `nim-z3`, `softlink`, and both the main `chronos` checkout and
this worktree (the worktree lives under
`.../libs/chronos/.claude/worktrees/...`, itself under the same mount):

```sh
podman run --rm --userns=keep-id \
  -v /home/corey/projects/nim/libs:/home/corey/projects/nim/libs:z \
  --env HOME=/home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase/verify/.container-home \
  --env USER=corey \
  --workdir /home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase/verify \
  localhost/chronos-verify:latest \
  sh -c './run.sh all'
```

Or run one layer at a time (`./run.sh symex`, `./run.sh bmc`, `./run.sh
drift`). Each is a plain Nim program: `doAssert`-driven, non-zero exit on
any unexpected verdict, human-readable progress to stdout. Total runtime
for layers 1-2 plus the drift check is a few seconds — well inside the
RFC's "minutes, harness container only" budget.

**S11 layers 3-4** (`bisim`, `fuzz`) are MM-sensitive — run once per MM by
setting `MM` before the `podman run` (or inside the container before
`./run.sh`):

```sh
podman run --rm --userns=keep-id \
  -v /home/corey/projects/nim/libs:/home/corey/projects/nim/libs:z \
  --env HOME=/home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase/verify/.container-home \
  --env USER=corey \
  --env MM=refc \
  --workdir /home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase/verify \
  localhost/chronos-verify:latest \
  sh -c './run.sh bisim'   # then MM=orc, then ./run.sh fuzz for each MM
```

Layers 3-4 import the REAL `chronos/internal/callbackqueue.nim` directly
(no more mirroring — see "Why layers 1-2 still use mirrors, but 3-4 don't"
below), so no rebuild of `verify/`'s own files is needed when
`chronos/internal/callbackqueue.nim` changes; the next `./run.sh` picks it
up through the bind mount. Runtime: layer 3 (bisim) is a few hundred
milliseconds per MM (a small, exhaustively-dedup'd BFS); layer 4 (fuzz) is
single-digit-to-twenties of seconds per MM at its configured iteration
count (see the Layer 4 section below).

**S11 layer 5** (mutation testing) has no `run.sh` case — it mutates the
tracked `chronos/internal/callbackqueue.nim` directly, which `run.sh`
deliberately never does on its own. See the Layer 5 section below for the
methodology, the patches under `verify/mutants/`, and how to reproduce a
single mutant's check.

## Proof ledger

Every named invariant, its verdict, and the checker/bound that produced it.
No silent gaps: everything not PROVEN/VERIFIED below is explicitly
deferred, with a reason.

### Layer 1 — symex (`symex_checks.nim`)

| Invariant | Verdict | Checker | Bound |
|---|---|---|---|
| `capMask`: totality (assert never fires) + `capMask(cap) == cap - 1`, `>= 0` | **PROVEN** | `symexFind(checkCapMask, tAssertionViolation())` → `sxUnsat` | `cap` a positive power of two; unbounded magnitude (bitwise AND cannot overflow) |
| `slotIndex`: result in `[0, cap)` over the **full int domain for `pos`**, including negative — subsumes the addFirst edge (`dec head` after repeated sentinel reinsertions) | **PROVEN** | `symexFind(checkSlotIndexRange, tAssertionViolation())` → `sxUnsat` | `cap` a positive power of two; `pos` fully unconstrained (proof is strictly stronger than "one decrement below zero") |
| `queueLen`: totality + `queueLen(head,tail) == tail - head`, `>= 0` | **PROVEN** | `symexFind(checkQueueLen, tAssertionViolation())` → `sxUnsat` | `tail >= head`; `head`/`tail` bounded to `[-2^40, 2^40]` (see Findings — unbounded, `tail - head` genuinely overflows) |
| `isFull`: agrees with `queueLen(head,tail) >= cap` | **PROVEN** | `symexFind(checkIsFull, tAssertionViolation())` → `sxUnsat` | same bounds as `queueLen`, plus `cap` a positive power of two |
| `growTargetCap`: totality + strict growth (`g > cap`) + exact doubling/8-floor | **PROVEN** | `symexFind(checkGrowTargetCap, tAssertionViolation())` → `sxUnsat` | `0 <= cap <= 2^40` (unbounded, `cap * 2` overflows near `int.high` — see Findings) |
| Wrapped-region growth sweep: both `copyMem` segments' index arithmetic stays in-bounds and jointly covers exactly `n` items once each (`n == oldCap`, per `grow()`'s own precondition) | **PROVEN** | `symexFind(checkGrowSweep, tAssertionViolation())` → `sxUnsat` | `oldCap` a positive power of two, `<= 2^40`; `head` fully unconstrained (bitwise-AND-only downstream use, no overflow path) |

**Deferred to S10's codegen tier (stated, not silent):**

- **Heap-slot relocation soundness at the real allocator/MM level**
  (`copyMem`+`zeroMem` neither creating nor destroying a GC-visible count
  when relocating already-counted refs between traced heap slots). Symex
  reasons over int/bool arithmetic only — no seqs, no refs, no MM (D9-V's
  own stated layer-1 ceiling). This is exactly what layer 2's ghost model
  targets at the ownership-bookkeeping level (see below) and what S11's
  fuzz+GC-stress layer targets at the real-allocator level.
- **`cap`/`head`/`tail` magnitudes beyond `2^40`.** Genuine `OverflowDefect`
  findings at the extreme end of the int64 domain (`growTargetCap`'s
  doubling; `queueLen`'s subtraction) — both require the queue to have
  processed on the order of 2^40–2^63 operations in one process lifetime,
  which is physically unreachable (exabytes of `AsyncCallback` slots, or
  longer than any process runs). Bounded out with a stated reason, the same
  posture the RFC's own D9 prose already takes toward comparable edges —
  not silently avoided; see Findings below for how each was discovered.

### Layer 2 — bmcCheck ghost-ownership model (`bmc_ghost.nim`)

Six runs: two dequeue shapes (`FUSED` = D9's adopted `chronosMoveSink`
template; `REJECTED` = round 4's rejected `copyMem`-to-stack-local template)
× three invariants. `maxDepth=12`, `maxStates=20000`, `initialCap=2`
(deliberately small so growth is exercised well inside the swept depth: cap
must double at least twice, 2→4→8, on any all-`enqueue` prefix within 12
steps — the wrapped-region growth path is therefore reached on every run,
not left to chance). Structural, id-relabeling-invariant `stateHash` dedup
keeps exploration in the low hundreds of states.

| Shape | Invariant | Verdict | Checker/bound |
|---|---|---|---|
| FUSED | Refcount conservation (`trueRefCount[id] == 1` iff a tracked holder claims it, else `0`, for every captured id) | **VERIFIED** | `bmcCheck`, depth 12, 82 states explored |
| FUSED | Vacated-slot-zeroed (no non-nil ghost slot survives a full drain) | **VERIFIED** | `bmcCheck`, depth 12, 82 states explored |
| FUSED | No primitive-level `doAssert` fires across any reachable plan | **VERIFIED** | `bmcCheck`, depth 12, 82 states explored (via `Defect`→`CatchableError` conversion — see Findings) |
| REJECTED | Refcount conservation | **FALSIFIED** (by design — see below) | `bmcCheck`, shortest counterexample plan `[enqueue, dequeue]`, depth 2 |
| REJECTED | Vacated-slot-zeroed | **VERIFIED** | `bmcCheck`, depth 12, 144 states explored |
| REJECTED | No primitive-level `doAssert` fires | **VERIFIED** | `bmcCheck`, depth 12, 144 states explored |

**The required finding (RFC 0001 S9 exit criteria, part a):** the REJECTED
shape's refcount-conservation run is FALSIFIED, with the shortest possible
counterexample — a two-step plan, `enqueue` then `dequeue`. After that
single `dequeue` (which internally runs `popFirstRejected`: `copyMem` the
slot into a stack local, then `zeroMem` the slot), the ledger shows
`trueRefCount[id] == 1` but no tracked holder claims `id` — the sole counted
reference was stripped without a decrement. This is precisely the
"unreclaimable node" the RFC's rejected-shapes analysis (D9, round 4)
describes in prose; the model reproduces it mechanically, from a real
`copyMem`/`zeroMem` pair running against the real `CallbackQueue[T]`
backing store, not from a hand-simulated abstraction.

**The verification (part b):** the FUSED shape (D9's adopted
`chronosMoveSink`-fused `popFirst`) VERIFIES refcount conservation across
every reachable plan up to depth 12 — the atomic transfer (same ledger
entry relocates from `tlSlot` to `tlCallerLocal` in one step, backed by the
real template's `wasMoved` semantics) never duplicates or drops a count.

**Why the REJECTED shape's *other* two invariants VERIFY (a control, not a
gap):** `vacatedSlotZeroed` and `no-assert-fires` both hold for the
REJECTED shape too. This is intentional and diagnostic, not a weaker
finding — it isolates the bug precisely to the ledger (refcount
bookkeeping), not to memory safety or precondition violations: `zeroMem`
genuinely does clear the slot's raw bytes (no dangling read), and no
`doAssert` anywhere ever fires. The rejected shape's defect is *silent* —
which is exactly why a ghost-ownership model, not a runtime assertion or a
memory-safety check, is the only layer capable of catching it. That silence
is also why deferring this class of bug to "run the test suite and see" is
not viable; it would never fire.

**Deferred to S10's codegen tier / S11 (stated, not silent):**

- **Real-MM effects** (actual ARC/refc barrier calls, actual GC_ref/unref
  traffic, actual allocator behavior). `GhostItem` is a plain value type
  with no destructor by design — the ledger is explicit bookkeeping that
  *mirrors* what a real barrier/move/raw-memory-op would do, not something
  derived from Nim's own hooks. This is deliberate (D9-V's own stated
  layer-2 ceiling: "cannot prove: real-MM effects") — S11's fuzz + GC
  stress layer, run against S10's real implementation on both MMs, is where
  actual allocator behavior gets exercised.
- **Plan-depth-bounded coverage beyond 12 steps / states beyond the low
  hundreds.** A justified small bound per the RFC's stated budget
  ("minutes, harness container only"); S11's coverage-guided fuzz picks up
  where BMC's exhaustive-but-bounded sweep stops.

## Findings (for the control loop — none of these were fixed in D9's spec by this slice)

Recorded precisely, per RFC 0001 S9's stated purpose ("this slice may send
D9's design back for revision — that is its purpose"). None required a
design change to D9's queue *semantics*; all are either (a) a trivial
declaration-shape adjustment with zero runtime cost, or (b) a verification
tooling limitation with a confirmed, semantically-neutral workaround, or (c)
a physically-unreachable overflow edge, explicitly bounded rather than
silently avoided.

1. **D9's index primitives must be declared `proc`, not `func`.** The
   validated S9.0 spike (`ad569a3`) declares `capMask`/`slotIndex`/
   `queueLen`/`isFull`/`growTargetCap` as `func`. proptest's symex
   Phase-3 interprocedural resolution (`ensureProcRegistered`,
   `proptest/smt/dsl_parser.nim`) hard-errors on any callee whose
   `getImpl.kind != nnkProcDef` — `func` lowers to `nnkFuncDef` and is
   rejected outright, both as a direct `symexFind` target and as an
   interprocedural callee (`symex Phase 3: cannot resolve getImpl for
   callee 'capMask' — generic / private cross-module / built-in?`).
   D9's own RFC prose already specifies "pure int→int/bool **procs**" (not
   funcs); the spike's `func` was spike-only shorthand the S9.0 disposal
   rule already marks as not the S10 deliverable. **Action for S10:** keep
   `proc` (zero cost — `func` is pure sugar for `proc {.noSideEffect.}`);
   no spec change needed, just confirm the real implementation follows the
   RFC prose rather than the spike's shorthand.

2. **A proptest/symex walker limitation, not a D9 defect**, discovered
   while proving `capMask` and `slotIndex`: two related expression shapes
   crash the walker (`AssertionDefect: lowerBool: expected Bool, got
   svBV64`, `proptest/smt/runtime.nim:3345`) —
   - `doAssert (cap and (cap - 1)) == 0` — a bitwise-AND whose second
     operand is an inline arithmetic sub-expression of the *same* variable
     as the first operand.
   - `pos and capMask(cap)` / `queueLen(head, tail) >= cap` — a
     boolean-or-bitwise expression with a *direct*, non-let-bound
     function-call result as one operand, at interprocedural depth 2.

   Both are fixed by binding the sub-expression/call result to a named
   `let` first — confirmed empirically to produce identical proof results
   once applied (`primitives.nim`'s `capMask`/`slotIndex`/`isFull` all
   carry this hoist; `symex_checks.nim`'s `isPow2` helper and
   `checkGrowSweep`'s `newCap` local do the same at the call sites). This
   is semantically a no-op — identical codegen once optimized — so it
   carries no cost if S10 chooses not to mirror it in the shipped code (the
   spike's original one-line shapes remain fine to ship; only the
   symex-walked mirror in `verify/` needed the hoist to be provable at
   all). Filing this against proptest itself is out of this slice's scope.

3. **A genuine, but physically-unreachable, `OverflowDefect`** in
   `queueLen`'s `tail - head`: unconstrained, `head`/`tail` can range over
   the full int64 domain (e.g. `tail = int.high, head = int.low`), and the
   subtraction overflows under Nim's default checked arithmetic. Requires
   on the order of 2^63 queue operations in one process lifetime to reach —
   bounded out (`[-2^40, 2^40]`) for the same reason `growTargetCap`'s own
   `cap * 2` needs the analogous bound, not silently avoided. No action
   needed for D9's design; recorded so a future revisit of these bounds
   (should chronos ever run in some multi-decade, trillions-of-callbacks
   process — not a realistic target) knows where the edge is.

## S11 — harness build-out against the real queue

RFC 0001 §6 S11: layers 3-5, run against the REAL, shipped
`chronos/internal/callbackqueue.nim` (S10, `db43cff`) rather than S9's
throwaway mirrors — bisimulation vs `std/deques`, coverage-guided fuzz with
GC stress + occupied-memory leak accounting, and mutation scoring. Both
MMs for layers 3-4; mutation testing (layer 5) runs primarily under refc,
where the mutant classes tested here (write-barrier/relocation-adjacent
bugs) manifest most sharply — see the Layer 5 section for the exact legs
each mutant was checked against.

### Why layers 1-2 still use mirrors, but 3-4 don't

S9's `primitives.nim`/`callbackqueue_model.nim` were built before
`chronos/internal/callbackqueue.nim` existed, so they had nothing to
import. Now that S10 has shipped the real module, S11 was asked to point
layers 3-5 at it directly wherever practical, and to consider whether the
S9 mirrors are now redundant.

**Layers 3-4 (this slice): refactored to import the real module directly.**
`bisim_check.nim` and `fuzz_leak.nim` both `import ../chronos/internal/
callbackqueue` and exercise it through its five public entry points —
no duplication needed, because bisimulation and fuzzing only ever touch
the public interface.

**Layers 1-2 (S9, unchanged): still walk the mirrors, deliberately.**
Symex needs direct `proc`-level access to the five index primitives
(`capMask`, `slotIndex`, `queueLen`, `isFull`, `growTargetCap`) to state
and prove their pre/postconditions — but the real module keeps them
**private** (D9's own stated interface-narrowing rationale: "every
[external] touch goes through the five [public] procs/templates"), and
RFC 0001's non-goals explicitly freeze the public surface ("No API
changes: public surface is frozen post-review-round-4"). Exporting the
primitives just to satisfy a fork-only verification tool would be exactly
the kind of surface change that rule exists to prevent, so the mirrors
were kept rather than refactored away.

**The tradeoff needs a check, and now has one: `drift_check.nim`.** A
plain, dependency-free textual comparison (`nim c -r --mm:orc
drift_check.nim`, no proptest/z3) that re-reads both files and confirms
ten load-bearing substrings — each primitive's exact `doAssert` message,
plus the arithmetic/threshold expressions that survive S9's documented
symex-walker hoist unchanged (`cap - 1`, `tail - head`, `queueLen(head,
tail) >= cap`, the `growTargetCap` doubling rule) — appear verbatim in
both the real module and the mirrors. It deliberately does NOT diff whole
proc bodies (that would false-positive on the known, documented hoist
divergence in `capMask`/`slotIndex`/`isFull` — see Finding 2 above); a
change to `slotIndex`'s masking expression that preserves the checked
substrings could in principle slip past it, but layers 3 and 5 exercise
the real module's actual masking behavior at runtime regardless, so a
regression there is still caught, just not by this specific text check.
Ran clean: all ten checks matched.

### Layer 3 — bisimulation (`bisim_check.nim`)

Proptest's `bisimulationCheck` (#115): deterministic lock-step BFS over
`(realState, refState)` product pairs, comparing observations and
enabled-rule-name sets at every reached pair. Three shared rules —
`addLast`, `addFirst`, `popFirst` — against a real `CallbackQueue[int]`
on one side and a `std/deques.Deque[int]` reference on the other.
`addFirst`'s enabled-set (the real queue never grows on `addFirst` — D9's
stated scope) is computed via an independently-tracked shadow `cap` field
on both sides, updated by the same `growTargetCap` arithmetic
`drift_check.nim` confirms matches the real module — proved to stay in
lockstep inductively (equal at the initial state; only ever updated by the
one shared rule, `addLast`, identically on both sides). FIFO order is
proved per reached state by draining a VALUE COPY of the state (both
`CallbackQueue[T]` and `Deque[T]` have default deep-copy semantics), since
D9's interface has no peek/iteration by design.

`initialCap=2` (mirrors S9's `bmc_ghost.nim`), `maxDepth=12`,
`maxStates=20000`, structural `stateHash` (by `len`+shadow-`cap`) for
dedup.

| MM | outcome | pairs explored |
|---|---|---|
| refc | **EQUIVALENT** | 22 |
| orc | **EQUIVALENT** | 22 |

Both MMs: the real `CallbackQueue[int]` and the `std/deques` reference
agree on FIFO order, `len`, and enabled-op sets over every reachable plan
to depth 12 — growth and physical wraparound are reached on essentially
every branch given `initialCap=2` (the state space is small by
construction: reachable `(len, cap)` pairs at depth 12 number in the
dozens, so the low explored-state count reflects genuine exhaustiveness
under the dedup, not premature termination — confirmed by the mutation
matrix below, where every structural mutant this layer is capable of
seeing is caught at shallow depth, not missed).

### Layer 4 — coverage-guided fuzz + GC stress + leak accounting (`fuzz_leak.nim`)

Against a real `CallbackQueue[LeakItem]` (`LeakItem = ref object`, heap
allocated, GC-traced) — the only layer exercising the real allocator under
a real MM. `proptest/fuzz`'s `fuzzWith` (IR-mutation mode): random
op-sequence generation (`addLast`/`addFirst`/`popFirst`, `lists` +
`frequency` strategies, up to 300 ops/sequence) refined by the mutator
kernel's perturb-integer/kind-boundary/span-splice/delete/duplicate
transforms.

**Honestly scoped as "coverage-guided."** `fuzzWith` is edge-coverage
directed only when the SUT carries `{.cover.}` instrumentation.
`chronos/internal/callbackqueue.nim` is upstream-bound and must not carry
any fork-only pragma (the segregation mandate), so it is never
instrumented; per `proptest/fuzz.nim`'s own module doc, this degrades
gracefully to structural (uninstrumented) IR-mutation fuzzing. Still real
signal: the IR mutators explore op-sequence shape more effectively than
independent-draw random generation, and every finding is genuine either
way.

**Leak accounting.** Each `prop` call: replay a generated op sequence
against a FRESH queue, force a full drain regardless of how the sequence
ended, `GC_fullCollect()`, then assert `getOccupiedMem()` is within
`toleranceBytes` (1 MB) of a baseline captured once at program start
(after a warm-up round — both MMs show a one-time bump on the first
GC-traced allocations, then plateau; warming up before sampling avoids
mistaking that bump for drift).

**Calibration (real finding, confirms the check has teeth):** a temporary
one-line change (`chronosCalibrationLeakSink.add leaked` instead of
`discard` in the drain loop — applied, run, and reverted for this
calibration only, never committed) reliably tripped the assertion almost
immediately: the very first `prop()` call already exceeded baseline +
tolerance (`occ=1062752` vs. threshold `1062512`, refc). Confirms a
genuine per-op leak is caught within the first handful of iterations, not
after the whole budget is spent.

**Iteration budget.** 50,000 iterations, up to 300 ops each (up to 15M
queue operations per MM run). Chosen by scaling up from an initial 4,000
iterations (~1-2s/MM) — comfortable headroom under the "minutes, not
hours" budget:

| MM | iterations | wall clock | crashes | leak-accounting failures |
|---|---|---|---|---|
| refc | 50,000 | 19-21s | 0 | 0 |
| orc | 50,000 | 9-10s | 0 | 0 |

**Defect-unwind sequences.** `runDefectUnwindChecks` (run once, before the
fuzz loop): `popFirst()` on an empty queue and `addFirst()` on a full
queue both `doAssert`; under this fork's standing `panics:off` assumption,
both raise a catchable `Defect`, confirmed directly — and in both cases
the queue remains fully usable for subsequent ops afterward. Both PASS,
both MMs.

### Layer 5 — mutation scoring

Systematic mutants applied directly to the tracked
`chronos/internal/callbackqueue.nim` (mechanical apply → check → revert,
via `git checkout`), one unified diff per mutant saved under
`verify/mutants/*.patch` for reproducibility. Each mutant was checked
against three legs: (A) `tests/testcallbackqueue.nim`, plain
(`-d:release --mm:refc`); (B) the same file under the standard matrix's
debug leg (`-d:debug -d:chronosDebug -d:useSysAssert -d:useGcAssert
--mm:refc`); (C) `bisim_check.nim` (`--mm:refc`). A mutant surviving all
three escalates to (D) `fuzz_leak.nim` (`--mm:refc`).

Reproduce a single mutant, e.g. M3:

```sh
cd /home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase
git apply verify/mutants/m3_dropped_zeromem.patch
# ... run legs A/B/C/D as below ...
git checkout -- chronos/internal/callbackqueue.nim   # ALWAYS revert
```

| # | mutant | class | killed by | notes |
|---|---|---|---|---|
| M1 | `addLast`: `inc q.tail` → `q.tail += 2` | off-by-one head/tail | A, B, C (depth 1) | 8/10 plain tests fail; bisim distinguishes on the first `addLast` |
| M2 | `capMask`: return `cap` instead of `cap - 1` | wrong mask | A, B, C (depth 1) | 8/10 plain tests fail; bisim distinguishes on the first `addFirst` |
| M3 | `grow()`: drop the first segment's `zeroMem` | dropped zeroMem | **D only** (A/B/C survive) | Silent double-decref (real module's own doc comment predicts this exactly); SIGSEGV in `fuzz_leak.nim` after ~8500 iterations under refc. **Distilled**: new pin added to `tests/testcallbackqueue.nim` ("repeated growth cycles preserve ref-field values under memory pressure") — 200 growth cycles + allocator noise, now reliably reproduces the SIGSEGV under plain leg A too. Re-verified: real (unmutated) code passes the new pin cleanly on both MMs. |
| M4 | `grow()`: swap the two `copyMem` destinations (`newData[0]` ↔ `newData[firstSeg]`) | swapped copyMem segments | A, B, C (depth 3) | SIGSEGV in both plain and debug legs; bisim distinguishes after 3 `addLast`s |
| M5 | `popFirst`: drop `chronosMoveSink`, both branches | dropped sink/move | **B only** (A, C survive) | Plain leg A passes (refc's normal seq-destructor at `prop()`'s scope exit still decrefs the stale slot — no *observable* corruption at this scale); leg B's existing `chronosDebug` guardrail canary (already shipped, RFC 0001 D9) fails 10/11 tests immediately. No new pin needed: the standard 6-leg matrix's debug leg already exercises this canary on every `nimble test` run. |
| M6 | canary: `==` → `!=` in the vacated-slot-zeroed `doAssert` | wrong sentinel/zero compare | **B only** (A, C survive) | Same shape as M5: leg B fails immediately (10/11) on the very first `popFirst()`; leg A/C don't reach the `chronosDebug`-gated canary at all. No new pin needed, same reasoning as M5. |

**All six mutants killed.** Zero survivors. M3 is the slice's one genuine
finding — see "S11 findings" appended to RFC 0001 §1 — and is now closed
by a distilled, plain-`unittest2` regression pin; M5/M6 confirm the
existing `chronosDebug` guardrail canary (shipped at S10) is load-bearing
and already covered by the standing matrix, not merely decorative; M1/M2/M4
confirm layers 3-4 (and the pre-existing test suite) have real teeth
against the more overt structural bug classes without needing escalation.

## Re-running

```sh
cd /home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase
podman build -t localhost/chronos-verify:latest -f verify/Containerfile verify
podman run --rm --userns=keep-id \
  -v /home/corey/projects/nim/libs:/home/corey/projects/nim/libs:z \
  --env HOME=/home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase/verify/.container-home \
  --env USER=corey \
  --workdir /home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase/verify \
  localhost/chronos-verify:latest \
  sh -c './run.sh all'
```

S11 layers 3-4, both MMs (run from the same container/mount, `.docker-home`
as `HOME` instead if you also want `tests/testcallbackqueue.nim` runnable
in the same session — it needs `unittest2` off the nimble path, which
`.container-home` does not carry):

```sh
cd /home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase
for mm in refc orc; do
  podman run --rm --userns=keep-id \
    -v /home/corey/projects/nim/libs:/home/corey/projects/nim/libs:z \
    --env HOME=/home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase/verify/.container-home \
    --env USER=corey --env MM=$mm \
    --workdir /home/corey/projects/nim/libs/chronos/.claude/worktrees/contextvars-rebase/verify \
    localhost/chronos-verify:latest \
    sh -c './run.sh bisim && ./run.sh fuzz'
done
```
