# verify/ — fork-only D9 verification harness (RFC 0001 S9)

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
mutation scoring) are S11's job, against the real implementation once S10
ships it.

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
| `nim.cfg` | The three sibling `--path:` lines (`proptest`, `nim-z3`, `softlink`) + one `chronos/` path for `config.nim`. |
| `Containerfile` | Derived, throwaway image (`FROM ghcr.io/coreyleavitt/nim:2.2.10`); never modifies the shared base. |
| `run.sh` | `verify/run.sh <symex\|bmc\|all>` — the only supported entry point. |

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

Or run one layer at a time (`./run.sh symex`, `./run.sh bmc`). Each is a
plain Nim program: `doAssert`-driven, non-zero exit on any unexpected
verdict, human-readable progress to stdout. Total runtime for both layers
is a few seconds — well inside the RFC's "minutes, harness container only"
budget.

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
