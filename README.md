# Tonalli

Tonalli is a hard fork of [nim-chronos](https://github.com/status-im/nim-chronos) developing an efficient async/await runtime for Nim, with a deterministic simulation testing substrate and, over time, its own engine (dispatcher port boundary, completion backends).

## Relationship to chronos

Tonalli is a friendly fork -- chronos remains the upstream merge source, and targeted fixes flow back upstream when they apply there too (status-im/nim-chronos#703 merged; status-im/nim-chronos#702 open). Module names are still `chronos*` for now; renames to `tonalli*` are staged for later and have not happened yet, so the usage examples below are accurate as written.

## Introduction

Tonalli is an efficient [async/await](https://en.wikipedia.org/wiki/Async/await) framework for Nim. Features include:

* Asynchronous socket and process I/O
* HTTP server with SSL/TLS support out of the box (no OpenSSL needed)
* Synchronization primitivies like queues, events and locks
* Cancellation
* Efficient dispatch pipeline with excellent multi-platform support
* Exceptional error handling features, including `raises` tracking

## Getting started

Install `chronos` using `nimble`:

```text
nimble install chronos
```

or add a dependency to your `.nimble` file:

```text
requires "chronos"
```

and start using it:

```nim
import chronos/apps/http/httpclient

proc retrievePage(uri: string): Future[string] {.async.} =
  # Create a new HTTP session
  let httpSession = HttpSessionRef.new()
  try:
    # Fetch page contents
    let resp = await httpSession.fetch(parseUri(uri))
    # Convert response to a string, assuming its encoding matches the terminal!
    bytesToString(resp.data)
  finally: # Close the session
    await httpSession.closeWait()

echo waitFor retrievePage(
  "https://raw.githubusercontent.com/status-im/nim-chronos/master/README.md")
```

## Documentation

See the [user guide](https://status-im.github.io/nim-chronos/).

## Deterministic simulation

Tonalli adds a deterministic simulation substrate for testing async code:
a test can run the event loop over a seeded, injectable source of
nondeterminism instead of the real clock, selector, and network stack,
so a failing interleaving reproduces from a single seed. See
[docs/src/simulation.md](docs/src/simulation.md).

## Projects using `chronos`

* [libp2p](https://github.com/status-im/nim-libp2p) - Peer-to-Peer networking stack implemented in many languages
* [presto](https://github.com/status-im/nim-presto) - REST API framework
* [Scorper](https://github.com/bung87/scorper) - Web framework
* [2DeFi](https://github.com/gogolxdong/2DeFi) - Decentralised file system
* [websock](https://github.com/status-im/nim-websock/) - WebSocket library with lots of features

`chronos` is available in the [Nim Playground](https://play.nim-lang.org/#ix=2TpS)

Submit a PR to add yours!

## TODO
  * Multithreading Stream/Datagram servers

## Contributing

When submitting pull requests, please add test cases for any new features or fixes and make sure `nimble test` is still able to execute the entire test suite successfully.

`chronos` follows the [Status Nim Style Guide](https://status-im.github.io/nim-style-guide/).

## License

Tonalli is offered under the Apache License, Version 2.0
([LICENSE-APACHEv2](LICENSE-APACHEv2)). Code inherited from chronos was
received under chronos's Apache-2.0 option of its dual Apache-2.0/MIT
offer; [LICENSE-MIT](LICENSE-MIT) is retained in-tree solely so
inherited files' license notices keep valid references. All
tonalli-original code is Apache-2.0 only. Copyright on inherited files
remains with Status Research & Development GmbH; tonalli-original files
are (c) Corey Leavitt.
