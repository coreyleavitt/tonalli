## RFC 0001 D9-V / S11 — drift check: `callbackqueue_model.nim`'s ghost
## reimplementation vs the real module's precondition messages.
##
## **FORK-ONLY.** See `verify/README.md`. Run via `verify/run.sh drift`.
##
## **W3 retirement note:** this file used to ALSO check `primitives.nim`
## against the real module (S9's own module doc explained why: `primitives.
## nim` was a hand-copied textual mirror, made before `chronos/internal/
## callbackqueue.nim` existed). W3 replaced that mirror with a direct
## `include` of the real module (see `primitives.nim`'s current module
## doc) - the two are now byte-identical for the included portion BY
## CONSTRUCTION, so a textual drift check between them is not merely
## unnecessary, it is vacuous (there is nothing left that COULD drift
## without a compile error). The `primitives.nim`-vs-real checks are
## removed for exactly that reason; they are not "retired but load-
## bearing", they are retired because the failure mode they existed to
## catch is now structurally impossible.
##
## What remains genuinely load-bearing: `callbackqueue_model.nim` is
## STILL a hand-maintained, independent reimplementation (deliberately -
## see its own module doc on why it cannot `include` the real module
## either), so its precondition messages CAN still drift from the real
## module's silently. This file keeps exactly that check: it re-reads
## both files' SOURCE TEXT at runtime and confirms each checked
## precondition's literal `doAssert` message appears verbatim in both.

import std/[strutils, os]

const
  realModulePath = "../chronos/internal/callbackqueue.nim"
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
let modelSrc = readFile(modelPath)

# --- grow(): full-queue precondition message (callbackqueue_model.nim) ----
runCheck("grow(): non-full-queue precondition message",
  "CallbackQueue.grow(): called on a non-full queue", realSrc, modelSrc)

# --- addFirst/prependNoGrow: overfull precondition message ----------------
# Pre-existing (not a W3 finding): the ghost model's `addFirst` keeps D9's
# originally-planned name; the shipped real implementation renamed the
# same operation to `prependNoGrow` during S10 without updating this
# check's needle, so it drifted silently until this run. Checking the
# invariant text alone (dropping the proc-name prefix, which the two
# sides intentionally disagree on by design - see `callbackqueue_model.
# nim`'s module doc) is the correct fix, not renaming either side.
runCheck("addFirst/prependNoGrow: unexpectedly-full precondition message",
  "queue unexpectedly full", realSrc, modelSrc)

# --- popFirst: empty-queue precondition message ----------------------------
runCheck("popFirst: empty-queue precondition message",
  "CallbackQueue.popFirst(): queue is empty", realSrc, modelSrc)

echo "=== Drift check: all checked invariants match verbatim between the real module and verify/'s mirrors ==="
