#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Cross-module fixture for `testcontextvarsexport.nim`. Declares one
## starred (exported) and one non-starred (module-private) key via the
## `{.contextVar.}` pragma, plus one raw-constructed key that is itself
## unexported but dump-visible (`private = false`, passed explicitly
## against the raw constructor's own `private = true` default) — the
## export-decoupling case documented in docs/src/contextvars.md,
## "Privacy and the raw constructor".

import ../chronos/contextvars

let exportedVar* {.contextVar.} = 1
let privateVar {.contextVar.} = 2

let rawUnexportedRegistered = newContextVar("rawUnexportedRegistered", 3,
                                             private = false)
  ## No `*`: unreachable by name from an importing module. Still
  ## dump-visible (`private = false`, passed explicitly here — the
  ## constructor itself now defaults to `private = true`), so it
  ## surfaces in another module's `dumpContext` regardless — the raw
  ## constructor's `private` param is decoupled from Nim's own export
  ## marker, unlike the pragma above.
