# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# Lives here rather than nim.cfg: milpa owns nim.cfg (`milpa fetch`
# regenerates it with the _deps --path set).
switch("nimcache", "build/nimcache/" & projectName())

# This is workaround for `mingw64-gcc-12.1.0` issue.
# https://github.com/nim-lang/Nim/pull/19197
# Should be removed when https://github.com/status-im/nim-chronos/issues/284
# will be implemented.
switch("define", "nimRawSetjmp")
