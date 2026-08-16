## Drift check: `callbackqueue_model.nim`'s ghost reimplementation vs the
## real module's precondition messages.
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh drift`.
##
## `primitives.nim` now `include`s the real module directly (see its
## module doc), so it is byte-identical to the real module by
## construction and needs no drift check of its own. `callbackqueue_model.
## nim` is still a hand-maintained, independent reimplementation
## (deliberately - see its own module doc on why it cannot `include` the
## real module either), so its precondition messages CAN still drift from
## the real module's silently. This file re-reads both files' SOURCE TEXT
## at runtime and confirms each checked precondition's literal `doAssert`
## message appears verbatim in both.

import std/[strutils, os]

const
  realModulePath = "../tonalli/internal/callbackqueue.nim"
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

echo "=== Drift check: verify/ mirrors vs tonalli/internal/callbackqueue.nim ==="

if not fileExists(realModulePath):
  echo "FATAL: " & realModulePath & " not found (run from verify/ with the worktree layout intact)"
  quit(1)

let realSrc = readFile(realModulePath)
let modelSrc = readFile(modelPath)

# --- grow(): full-queue precondition message (callbackqueue_model.nim) ----
runCheck("grow(): non-full-queue precondition message",
  "CallbackQueue.grow(): called on a non-full queue", realSrc, modelSrc)

# --- addFirst/prependNoGrow: overfull precondition message ----------------
# The ghost model keeps the name `addFirst`; the shipped implementation
# uses `prependNoGrow` for the same operation (see `callbackqueue_model.
# nim`'s module doc). Checking the invariant text alone, dropping the
# proc-name prefix the two sides intentionally disagree on, is correct.
runCheck("addFirst/prependNoGrow: unexpectedly-full precondition message",
  "queue unexpectedly full", realSrc, modelSrc)

# --- popFirst: empty-queue precondition message ----------------------------
runCheck("popFirst: empty-queue precondition message",
  "CallbackQueue.popFirst(): queue is empty", realSrc, modelSrc)

echo "=== Drift check: all checked invariants match verbatim between the real module and verify/'s mirrors ==="
