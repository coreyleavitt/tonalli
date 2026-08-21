mode = ScriptMode.Verbose

packageName   = "tonalli"
# keep in sync: tonalli/apps/http/httpagent.nim
version       = "5.0.0"
author        = "Status Research & Development GmbH"
description   = "Networking framework with async/await support"
license       = "MIT or Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 2.2.10",
         "results",
         "stew >= 0.5.0",
         "bearssl >= 0.2.8",
         "httputils",
         "unittest2"

when (NimMajor, NimMinor, NimPatch) < (2, 2, 10):
  {.error: "tonalli requires Nim >= 2.2.10 (RFC 0012)".}

import os, strutils

let nimc = getEnv("NIMC", "nim") # Which nim compiler to use
let lang = getEnv("NIMLANG", "c") # Which backend (c/cpp/js)
let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let verbose = getEnv("V", "") notin ["", "0"]
let platform = getEnv("PLATFORM", "")
let testRunner = getEnv("NIM_TEST_RUNNER", "")
let testSuccessMarker = getEnv("NIM_TEST_SUCCESS_MARKER", "")
let testArguments =
  when defined(windows):
    [
      "-d:debug -d:tonalliDebug -d:useSysAssert -d:useGcAssert",
      "-d:release",
    ]
  else:
    [
      "-d:debug -d:tonalliDebug -d:useSysAssert -d:useGcAssert",
      "-d:debug -d:tonalliDebug -d:tonalliEventEngine=poll -d:useSysAssert -d:useGcAssert",
      "-d:debug -d:tonalliDebug -d:tonalliPreviewV5 -d:useSysAssert -d:useGcAssert",
      "-d:release -d:tonalliPreviewV5",
      # Pins the vacated-slot canary's no-sink branch (tonalliUseSink
      # gates `tonalliMoveSink`'s identity-passthrough fallback) on
      # every toolchain, not just whichever default tonalliUseSink picks.
      "-d:debug -d:tonalliDebug -d:tonalliUseSink=false -d:useSysAssert -d:useGcAssert",
    ]

let cfg =
  " --styleCheck:usages --styleCheck:error" &
  (if verbose: "" else: " --verbosity:0 --hints:off") &
  " --skipParentCfg --skipUserCfg --outdir:build " &
  quoteShell("--nimcache:build/nimcache/$projectName")

proc build(args, path: string) =
  exec nimc & " " & lang & " " & cfg & " " & flags & " " & args & " " & path

proc execTest(executable: string, args: varargs[string]) =
  # Cross-compiled tests need adb or simctl instead of direct host execution;
  # this is the one place that indirection is applied.
  var cmd =
    if testRunner.len == 0: quoteShell(executable)
    else: testRunner & " " & quoteShell(executable)
  for a in args:
    cmd &= " " & quoteShell(a)
  exec cmd

proc run(args, path: string) =
  build args, path
  execTest("build/" & path.splitPath[1])

proc tryExec(cmd: string) =
  try:
    exec cmd
  except Exception as e:
    echo e.msg

# Kept in sync with the suite-name consts referenced from
# tests/testcontextvarsstandalone.nim; the binary's own `list` argument
# lets the desktop test legs catch drift between the two.
const contextVarsSuiteNames = [
  "contextvars: tonalliDebug context-corruption detection net",
  "contextvars (raw key): cross-thread construction detection",
  "contextvars (raw key): guard against a dead recording thread",
  "contextvars (raw key): tonalliDebug construction lock",
]

proc runContextVarsStandalone(args: string) =
  # testcontextvarsstandalone cannot run as a single `run` step: its
  # suites need process isolation from each other (see the binary's
  # doc comment), so each is dispatched as its own unittest2 filter,
  # routed through the same runner indirection as every other test.
  build args, "tests/testcontextvarsstandalone"
  if testRunner.len == 0:
    # Cross-compiled binaries cannot run on the host, so this drift
    # check only applies to the desktop legs, which always run it.
    # unittest2 prints its own suite headers as a side effect of
    # importing the four suites, ahead of the binary's own `list`
    # handling, so the output is these four names plus surrounding
    # unittest2 noise rather than the four lines alone - a containment
    # check is what's actually verifiable here, not output equality.
    let (output, code) = gorgeEx("build/testcontextvarsstandalone list")
    doAssert code == 0, "testcontextvarsstandalone list failed: " & output
    var missing: seq[string]
    for suiteName in contextVarsSuiteNames:
      if suiteName notin output:
        missing.add suiteName
    if missing.len > 0:
      echo "testcontextvarsstandalone suite list drifted from tonalli.nimble:"
      echo "  tonalli.nimble expects   : ", contextVarsSuiteNames
      echo "  missing from binary list : ", missing
      quit(1)
  for suiteName in contextVarsSuiteNames:
    execTest("build/testcontextvarsstandalone", suiteName & "::*")

proc buildChapter(chapterDir: string) =
  # Resolve the engine dependency against this checkout, not the registry.
  writeFile(chapterDir / "nimble.develop", """{
  "version": 1,
  "includes": [],
  "dependencies": [
    "../../.."
  ]
}
""")
  withDir(chapterDir):
    exec "nimble build"

task examples, "Build examples":
  # Build book examples
  for file in listFiles("examples"):
    if file.endsWith(".nim"):
      build "--threads:on", file

  # Build HTTP client tutorial examples
  for chapterDir in listDirs("examples/http_client"):
    buildChapter(chapterDir)

  # Build HTTP server tutorial examples
  for chapterDir in listDirs("examples/http_server"):
    buildChapter(chapterDir)

task benchmarks, "Run benchmarks":
  # Make sure benchmarks compile
  for f in walkDirRec("benchmarks"):

    if f.extractFilename.startsWith("bench_") and f.endsWith(".nim"):
      run "-d:release", f[0..^5]

task test, "Run all tests":
  for args in testArguments:
    # First run tests with `refc` memory manager.
    run args & " --mm:refc", "tests/testall"
    # testcontextvarsstandalone is its own step, not part of testall: it
    # covers the contextvars suites that cannot share testall's binary
    # (testcontextvarsleakguard deliberately lets an AssertionDefect
    # escape poll() under tonalliDebug; testcontextvarslock's tonalliDebug
    # construction lock is one-way for the process's lifetime).
    runContextVarsStandalone(args & " --mm:refc")
    run args & " --mm:orc", "tests/testall"
    runContextVarsStandalone(args & " --mm:orc")

  # Make sure benchmarks compile.
  for f in walkDirRec("benchmarks"):
    if f.extractFilename.startsWith("bench_") and f.endsWith(".nim"):
      build "", f[0..^5]

  if testSuccessMarker.len > 0:
    # Mobile CI uses this to confirm that the full task reached its end.
    writeFile(testSuccessMarker, "")

task test_v3_compat, "Run all tests in v3 compatibility mode":
  for args in testArguments:
    # First run tests with `refc` memory manager.
    run args & " --mm:refc -d:tonalliHandleException", "tests/testall"

    run args & " -d:tonalliHandleException", "tests/testall"

task test_simulation, "Run the deterministic simulation suites":
  # The sim substrate is fork-only test infrastructure. `tonalliEventEngine`
  # is left at its platform default throughout: the selector backend still
  # compiles as dead code under `chronosSimulation`, and sim behavior is
  # engine-independent by construction.
  let simArgs =
    "-d:debug -d:tonalliDebug -d:useSysAssert -d:useGcAssert " &
    "-d:chronosSimulation -d:tonalliFutureTracking --threads:on"
  let simLeafTests = [
    "tests/testsimclock", "tests/testsimengine", "tests/testsimloop",
    "tests/testsimoracle", "tests/testsimtrace", "tests/testsimulation",
    "tests/testsimstream", "tests/testsimnet", "tests/testsimdatagram",
    "tests/testsimproducer", "tests/testsimledger", "tests/testsimhttp",
    "tests/testsimreplay",
  ]

  run simArgs & " --mm:refc", "tests/testall"
  for t in simLeafTests:
    run simArgs & " --mm:refc", t

  run simArgs & " --mm:orc", "tests/testall"
  for t in simLeafTests:
    run simArgs & " --mm:orc", t

task simulation_identity, "Run the fixed-seed identity fixture, producing build/identity-trace.ndjson":
  let simArgs =
    "-d:debug -d:tonalliDebug -d:useSysAssert -d:useGcAssert " &
    "-d:chronosSimulation -d:tonalliFutureTracking --threads:on --mm:refc"

  run simArgs, "tests/simidentity"

proc nimbleTaskArgs(taskName: string): seq[string] =
  ## A nimble task has no ordinary parameter list for its own extra
  ## command-line words - they arrive as part of the raw argv nimble
  ## hands this NimScript (`paramStr`/`paramCount`), after the compiler
  ## flags nimble itself prepends. Scanning for `taskName` and taking
  ## everything after it is the conventional way a task recovers them.
  var found = false
  for i in 0 .. paramCount():
    if found:
      result.add paramStr(i)
    elif paramStr(i) == taskName:
      found = true

task replay, "Replay a downloaded failing-seed trace: nimble replay <fixture-name> <trace-path>":
  let simArgs =
    "-d:debug -d:tonalliDebug -d:useSysAssert -d:useGcAssert " &
    "-d:chronosSimulation -d:tonalliFutureTracking --threads:on --mm:refc"

  build simArgs, "tests/simreplay"
  var cmd = quoteShell("build" / "simreplay")
  for arg in nimbleTaskArgs("replay"):
    cmd &= " " & quoteShell(arg)
  exec cmd

task check_windows, "Windows parity: semantic-check the library surface (fork issue #20)":
  # The dev container has no mingw (fork issue #20 gap 4), so this
  # substitutes `nim check`'s full semantic analysis - no C compiler
  # needed - for an actual cross-compile: every symbol/type error a
  # real Windows build would hit at the front end, though not
  # codegen-only issues, which stay CI's job.
  let winCfg = cfg & " --os:windows -d:windows"

  # (a) define-off: the real (non-simulation) Windows build must stay
  # unaffected by the sim substrate (RFC 0003 principle 2).
  exec nimc & " check " & winCfg & " tonalli.nim"

  # (b) define-on: the sim substrate's public surface, with the
  # dispatcher construction fork and provenance guards this slice
  # mirrors onto the Windows (IOCP) branch.
  exec nimc & " check " & winCfg &
    " -d:chronosSimulation -d:tonalliFutureTracking --threads:on tonalli/simulation.nim"

  # (c) sim test files. The RFC 0003 S3/S4 sim poll loop (fork issue
  # #20 gap 2) is now ported onto the Windows (IOCP) branch: the
  # touchpoint-template split shares its sim-mode iteration with
  # POSIX, and the registration surface / dispatcher-level sim
  # wrappers (addReader2/addWriter2/removeReader2/removeWriter2/
  # unregister2/simMarkReady/simScheduleArrival/simDecideIo/
  # simProducerPost) exist for sim-minted fds, so every sim leaf test -
  # and testall, which imports them - now checks clean. `testsimstream`
  # (S10) guards its own probes out under `defined(windows)`:
  # `fastWrite`'s eager path is a POSIX-only no-op by design (section
  # 4's Windows IOCP-emulation non-goal), so the file still
  # semantic-checks here even though its test bodies compile away to
  # nothing on this branch. `testsimproducer` (S13) runs unguarded on
  # every platform: arrival actors are dispatcher-level (the real MPSC
  # queue and `waking` flag), not seamed I/O, so they need no
  # Windows-specific carve-out.
  let simLeafTests = [
    "tests/testsimclock", "tests/testsimengine", "tests/testsimloop",
    "tests/testsimoracle", "tests/testsimtrace", "tests/testsimulation",
    "tests/testsimstream", "tests/testsimnet", "tests/testsimdatagram",
    "tests/testsimproducer", "tests/testsimledger", "tests/testsimhttp",
    "tests/testsimreplay",
  ]
  for t in simLeafTests:
    exec nimc & " check " & winCfg &
      " -d:chronosSimulation -d:tonalliFutureTracking --threads:on " & t & ".nim"

  # (d) testall, define-on: exercises the sim leaf suites together with
  # the rest of the library in one binary. The S10 stream I/O seam is
  # POSIX-only (`chronos/transports/stream.nim`'s Windows branch is
  # untouched - see `testsimstream`'s comment above), so this checks
  # clean as of this slice.
  exec nimc & " check " & winCfg &
    " -d:chronosSimulation -d:tonalliFutureTracking --threads:on tests/testall.nim"

task test_libbacktrace, "test with libbacktrace":
  if platform != "x86":
    let allArgs = @[
      "-d:release --debugger:native -d:tonalliStackTrace -d:nimStackTraceOverride --import:libbacktrace",
    ]

    for args in allArgs:
      # First run tests with `refc` memory manager.
      run args & " --mm:refc", "tests/testall"
      run args & " --mm:orc", "tests/testall"

task docs, "Generate API documentation":
  exec "mdbook build docs"
  tryExec nimc & " doc " &
    "--git.url:https://github.com/coreyleavitt/tonalli --git.commit:master --outdir:docs/book/api --project tonalli"

  # Build the docs for modules that aren't part of the main module.
  for item in walkDir("tonalli/apps/http"):
    if item.kind == pcFile and item.path.splitFile().ext == ".nim":
      tryExec nimc & " doc " &
        "--git.url:https://github.com/coreyleavitt/tonalli --git.commit:master --outdir:docs/book/api/tonalli/apps/http " &
        item.path
