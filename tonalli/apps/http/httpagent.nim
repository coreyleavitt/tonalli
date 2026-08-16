#
#        Chronos HTTP/S client implementation
#             (c) Copyright 2021-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

{.push raises: [].}

import strutils

const
  TonalliName* = "tonalli"
    ## Project name string
  TonalliMajor* {.intdefine.}: int = 5
    ## Major number of Tonalli's version.
  TonalliMinor* {.intdefine.}: int = 0
    ## Minor number of Tonalli's version.
  TonalliPatch* {.intdefine.}: int = 0
    ## Patch number of Tonalli's version.
  TonalliVersion* = $TonalliMajor & "." & $TonalliMinor & "." & $TonalliPatch
    ## Version of Tonalli as a string.
  TonalliIdent* = "$1/$2 ($3/$4)" % [TonalliName, TonalliVersion, hostCPU,
                                     hostOS]
    ## Project ident name for networking services
