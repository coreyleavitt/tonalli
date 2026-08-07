#                Chronos Test Suite
#            (c) Copyright 2018-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Cross-module fixture for `testcontextvarsexport.nim`. Declares one
## starred (exported) and one non-starred (module-private) context var
## so export-marker semantics can be verified from an importing module.

import ../chronos/contextvars

contextVar:
  var exportedVar*: int = 1
  var privateVar: int = 2
