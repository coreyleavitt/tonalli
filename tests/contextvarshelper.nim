## Cross-module fixture for the `contextVar` export-marker test in
## `testcontextvarsexport.nim`. Declares one starred (exported) and
## one non-starred (module-private) context var so the export-marker
## semantics can be verified from an importing module — a private
## var's reader/binder must not be visible outside this module, while
## a starred var's must be fully usable from outside.

import ../chronos/contextvars

contextVar:
  var exportedVar*: int = 1
  var privateVar: int = 2
