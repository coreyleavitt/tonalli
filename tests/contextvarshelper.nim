## Cross-module fixture for `testcontextvarsexport.nim`. Declares one
## starred (exported) and one non-starred (module-private) context var
## so export-marker semantics can be verified from an importing module.

import ../chronos/contextvars

contextVar:
  var exportedVar*: int = 1
  var privateVar: int = 2
