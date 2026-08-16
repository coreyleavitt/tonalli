#                Chronos Test Suite
#            (c) Copyright 2026-Present
#         Status Research & Development GmbH
#
#              Licensed under either of
#  Apache License, version 2.0, (LICENSE-APACHEv2)
#              MIT license (LICENSE-MIT)

## Tests for the http layer's `SimBarrierError` envelope sites (RFC 0003
## fork issue #19 workstream 2, coverage-review Finding 7b):
## `httpserver.nim`'s `acceptClientLoop` and `httpclient.nim`'s
## `connect()` both catch a `SimBarrierError` crossing their `raises: []`
## boundary and re-raise it wrapped in a `Defect` (`raiseAsDefect`), the
## same idiom `chronos/simulation.nim`'s `runSimulation` recovers
## elsewhere. Constructing an `HttpServerRef` under a simulated
## dispatcher barriers during `HttpServerRef.new()` itself - at
## `createStreamServer()`'s `register2` call, before `acceptClientLoop`
## ever runs - so that envelope is provably unreachable through any
## normal codepath; the construction-time barrier is what this file pins
## instead, on the server side. The client side differs: session/request
## construction touches no real fd, so `httpclient.nim`'s own
## `connect()` envelope - not merely a construction-time barrier - is
## what a `fetch()` call reaches and is what this file drives for real.

{.used.}

when defined(chronosSimulation) and compileOption("threads"):
  import std/uri
  import unittest2
  import ../chronos
  import ../chronos/simulation
  import ../chronos/apps/http/[httpserver, httpclient]

  type
    ProbeOutcome = object
      ok: bool
      msg: string

  var probeChan: Channel[ProbeOutcome]
  probeChan.open()

  template runProbe(threadProc: typed): ProbeOutcome =
    var probeThread: Thread[void]
    createThread(probeThread, threadProc)
    let outcome = probeChan.recv()
    joinThread(probeThread)
    outcome

  proc process(r: RequestFence): Future[HttpResponseRef] {.
       async: (raises: [CancelledError]).} =
    defaultResponse()

  proc probeHttpServerConstructionBarriersUnderSim() {.thread.} =
    ## `HttpServerRef.new()` -> `createStreamServer()` ->
    ## `createAsyncSocket2()` -> `register2()`: a real fd registration,
    ## which a simulated dispatcher's provenance guard rejects before any
    ## socket syscall runs. Reached directly (not through a Defect
    ## envelope): `HttpServerRef.new()` only catches `TransportOsError`
    ## around this call, letting `SimBarrierError` propagate unchanged -
    ## `runSimulation`'s direct-propagation `SimBarrierError` case, the
    ## same one `tests/testsimulation.nim`'s
    ## `probeBodyBarrierHitClassifiedAsBarrierHit` already pins for a
    ## bare `addReader2`.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulate(seed = 50'u64):
        discard HttpServerRef.new(initTAddress("127.0.0.1:0"), process)
      outcome = ProbeOutcome(ok: false,
        msg: "HttpServerRef.new() did not barrier under simulation")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.BarrierHit:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
      elif exc.parent.isNil or not (exc.parent of SimBarrierError):
        outcome = ProbeOutcome(ok: false,
          msg: "parent was not a SimBarrierError")
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type escaped simulate(): " & exc.msg)
    probeChan.send(outcome)

  proc probeHttpClientConnectBarrierRecoversThroughDefectEnvelope() {.thread.} =
    ## Unlike the server side, `HttpSessionRef.new()` touches no real fd -
    ## the barrier is reached only once a request actually dials out, at
    ## `httpclient.nim`'s own `connect()` (~line 700): it catches the
    ## `SimBarrierError` the transport-level `connect()` raises and
    ## re-raises it wrapped in a `Defect` (`raiseAsDefect`), the envelope
    ## site this probe drives for real, not merely its construction-time
    ## twin.
    var outcome = ProbeOutcome(ok: true)
    try:
      simulate(seed = 51'u64):
        let session = HttpSessionRef.new()
        discard await session.fetch(parseUri("http://127.0.0.1:1/"))
      outcome = ProbeOutcome(ok: false,
        msg: "session.fetch() did not barrier under simulation")
    except SimulationError as exc:
      if exc.kind != SimFailureKind.BarrierHit:
        outcome = ProbeOutcome(ok: false, msg: "wrong kind: " & $exc.kind)
      elif exc.parent.isNil or not (exc.parent of SimBarrierError):
        outcome = ProbeOutcome(ok: false,
          msg: "parent was not a SimBarrierError")
    except CatchableError as exc:
      outcome = ProbeOutcome(ok: false,
        msg: "wrong exception type escaped simulate(): " & exc.msg)
    probeChan.send(outcome)

  suite "http SimBarrierError envelope sites":
    test "constructing an http server under simulation barriers at register2, classified BarrierHit":
      let outcome = runProbe(probeHttpServerConstructionBarriersUnderSim)
      checkpoint outcome.msg
      check outcome.ok

    test "an http client connect attempt barriers through httpclient.nim's own Defect envelope":
      let outcome = runProbe(probeHttpClientConnectBarrierRecoversThroughDefectEnvelope)
      checkpoint outcome.msg
      check outcome.ok
