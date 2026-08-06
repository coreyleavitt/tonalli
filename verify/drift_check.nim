## RFC 0001 D9-V / S11 — drift check: verify/'s mirrors vs the real module.
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh drift`.
##
## S9's `primitives.nim`/`callbackqueue_model.nim` are textual mirrors of
## D9's shape, hand-copied before `chronos/internal/callbackqueue.nim`
## existed (S9's own module doc explains why: nothing to import from at the
## time). S11 points layers 3-5 at the REAL module directly (no more
## copying), but layers 1-2 still walk the S9 mirrors, because symex needs
## direct `proc`-level access to the five index primitives and the real
## module deliberately keeps them **private** (D9's stated interface
## narrowing — "Private data/head/tail... every touch goes through the five
## [public] procs/templates"; exporting them to satisfy a verification tool
## would be the exact kind of public-surface change RFC 0001's non-goals
## rule out: "No API changes: public surface is frozen post-review-round-4").
## So the mirrors stay, and this file is the cheap, mechanical check that
## keeps them honest: it re-reads both files' SOURCE TEXT at runtime and
## confirms every primitive's invariant — its literal `doAssert` message,
## and the load-bearing arithmetic/branch shape of its body — appears
## verbatim in both.
##
## **Known, documented divergence this check must NOT flag** (S9's own
## finding #2, `verify/README.md`): `primitives.nim` hoists `capMask`'s
## `cap - 1` and `slotIndex`/`isFull`'s inner call results to named `let`s
## to work around a symex walker crash; the real module keeps the spike's
## original single-expression shapes. This check therefore compares
## doAssert MESSAGES (untouched by the hoist — pure string literals) and
## the handful of substrings that survive the hoist unchanged (`cap - 1`,
## the `growTargetCap` doubling arm), not full proc bodies. A genuine
## semantic drift — a changed invariant, a changed growth rule, a changed
## message — fails this check; the hoist itself does not.
##
## What this does NOT catch (stated, not silent): a change to `slotIndex`'s
## masking expression itself (`pos and capMask(cap)`) that preserves the
## substrings checked here would slip through — layer 1's symex proof
## covers `slotIndex`'s behavior directly (over the mirror, not the real
## module), and layers 3/5 (bisim, mutation) exercise the real module's
## actual masking behavior at runtime, so a masking regression is still
## caught, just not by this specific textual check.

import std/[strutils, os]

const
  realModulePath = "../chronos/internal/callbackqueue.nim"
  primitivesPath = "./primitives.nim"
  modelPath = "./callbackqueue_model.nim"

type
  Check = object
    label: string
    needle: string
    inReal: bool
    inMirror: bool

proc mustContain(haystack, needle: string): bool =
  needle in haystack

proc runCheck(label, needle: string; realSrc: string; mirrorSrc: string) =
  let inReal = mustContain(realSrc, needle)
  let inMirror = mustContain(mirrorSrc, needle)
  stdout.write "  " & label & " ... "
  if inReal and inMirror:
    echo "MATCH (present verbatim in both)"
  else:
    echo "DRIFT DETECTED"
    if not inReal:
      echo "    MISSING from " & realModulePath & ": " & needle
    if not inMirror:
      echo "    MISSING from mirror: " & needle
    doAssert false, label & ": drift between verify/'s mirror and the real module"

echo "=== D9-V S11 drift check: verify/ mirrors vs chronos/internal/callbackqueue.nim ==="

if not fileExists(realModulePath):
  echo "FATAL: " & realModulePath & " not found (run from verify/ with the worktree layout intact)"
  quit(1)

let realSrc = readFile(realModulePath)
let primitivesSrc = readFile(primitivesPath)
let modelSrc = readFile(modelPath)

# --- capMask: invariant message + the return arithmetic -------------------
runCheck("capMask: invariant message",
  "CallbackQueue: capacity must be a positive power of two", realSrc, primitivesSrc)
runCheck("capMask: return arithmetic (cap - 1)",
  "cap - 1", realSrc, primitivesSrc)

# --- queueLen: invariant message -------------------------------------------
runCheck("queueLen: invariant message",
  "CallbackQueue: tail must never precede head", realSrc, primitivesSrc)
runCheck("queueLen: return arithmetic (tail - head)",
  "tail - head", realSrc, primitivesSrc)

# --- isFull: agreement with queueLen >= cap --------------------------------
runCheck("isFull: threshold (queueLen(head, tail) >= cap)",
  "queueLen(head, tail) >= cap", realSrc, primitivesSrc)

# --- growTargetCap: invariant message + doubling rule ----------------------
runCheck("growTargetCap: invariant message",
  "CallbackQueue: capacity must not be negative", realSrc, primitivesSrc)
runCheck("growTargetCap: doubling rule (if cap == 0: 8 else: cap * 2)",
  "if cap == 0: 8 else: cap * 2", realSrc, primitivesSrc)

# --- grow(): full-queue precondition message (callbackqueue_model.nim) ----
runCheck("grow(): non-full-queue precondition message",
  "CallbackQueue.grow(): called on a non-full queue", realSrc, modelSrc)

# --- addFirst: overfull precondition message -------------------------------
runCheck("addFirst: unexpectedly-full precondition message",
  "CallbackQueue.addFirst(): queue unexpectedly full", realSrc, modelSrc)

# --- popFirst: empty-queue precondition message ----------------------------
runCheck("popFirst: empty-queue precondition message",
  "CallbackQueue.popFirst(): queue is empty", realSrc, modelSrc)

echo "=== Drift check: all checked invariants match verbatim between the real module and verify/'s mirrors ==="
