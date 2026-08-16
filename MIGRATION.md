# Migration: chronos to tonalli

As of version 5.0.0, this project renamed from chronos to tonalli. The rename
covers the package name, the import path, every `chronos*`-prefixed compile
flag and public symbol, the HTTP client's identity constants, and a handful
of runtime identity strings; it does not change any behavior. This document
is the closed reference for consumers updating an existing dependency. It
supersedes any `chronos*` name not listed as a deliberate exception below.

## Import path and package name

| Old | New |
|---|---|
| `import chronos` | `import tonalli` |
| `import chronos/X` (any submodule) | `import tonalli/X` |
| `requires "chronos"` in a `.nimble` file | `requires "tonalli"` |
| `nimble install chronos` | `nimble install tonalli` |

## Build defines

The following 18 compile-time flags renamed from `chronosX` to `tonalliX`.
Each is otherwise unchanged: same type, same default, same effect.

| Old | New | Kind |
|---|---|---|
| `-d:chronosConfig` | `-d:tonalliConfig` | bool (presence-checked) |
| `-d:chronosDebug` | `-d:tonalliDebug` | bool (presence-checked) |
| `-d:chronosDumpAsync` | `-d:tonalliDumpAsync` | booldefine |
| `-d:chronosEventEngine` | `-d:tonalliEventEngine` | strdefine |
| `-d:chronosEventsCount` | `-d:tonalliEventsCount` | intdefine |
| `-d:chronosFutureId` | `-d:tonalliFutureId` | booldefine |
| `-d:chronosFutureTracking` | `-d:tonalliFutureTracking` | booldefine |
| `-d:chronosHandleException` | `-d:tonalliHandleException` | booldefine |
| `-d:chronosInitialSize` | `-d:tonalliInitialSize` | intdefine |
| `-d:chronosPreviewV5` | `-d:tonalliPreviewV5` | bool (presence-checked) |
| `-d:chronosProcShell` | `-d:tonalliProcShell` | strdefine |
| `-d:chronosUseSink` | `-d:tonalliUseSink` | booldefine |
| `-d:chronosStackTrace` | `-d:tonalliStackTrace` | booldefine |
| `-d:chronosStreamDefaultBufferSize` | `-d:tonalliStreamDefaultBufferSize` | intdefine |
| `-d:chronosStrictFutureAccess` | `-d:tonalliStrictFutureAccess` | booldefine |
| `-d:chronosStrictReentrancy` | `-d:tonalliStrictReentrancy` | booldefine |
| `-d:chronosTLSSessionCacheBufferSize` | `-d:tonalliTLSSessionCacheBufferSize` | intdefine |
| `-d:chronosTransportDefaultBufferSize` | `-d:tonalliTransportDefaultBufferSize` | intdefine |

**Warning:** passing an old `-d:chronosX` flag does not error. Nim silently
ignores an unrecognized define; the build simply proceeds with that option
at its default rather than the value the caller intended. A build that
depended on a non-default `chronosX` setting (a larger buffer, a debug
helper, a strictness check) needs its `-d:` flags updated at the same time
as the import path, or it will pass without complaint at the old default.

## Renamed public symbols

| Old | New |
|---|---|
| `chronosHasRaises` | `tonalliHasRaises` |
| `chronosSink` | `tonalliSink` |
| `chronosMoveSink` | `tonalliMoveSink` |

`chronosStrictException` is removed, not renamed. It was already deprecated
before this rename and carries no replacement.

## HTTP agent constants

`tonalli/apps/http/httpagent.nim` renames its public identity constants:

| Old | New |
|---|---|
| `ChronosName` | `TonalliName` |
| `ChronosMajor` | `TonalliMajor` |
| `ChronosMinor` | `TonalliMinor` |
| `ChronosPatch` | `TonalliPatch` |
| `ChronosVersion` | `TonalliVersion` |
| `ChronosIdent` | `TonalliIdent` |

`TonalliMajor`/`TonalliMinor`/`TonalliPatch` are `{.intdefine.}`-overridable,
so the `-d:` keys used to override them at build time rename the same way:
`-d:ChronosMajor=X` becomes `-d:TonalliMajor=X`, and likewise for the minor
and patch components.

The default `User-Agent` header value changes accordingly, from
`chronos/<version> (...)` to `tonalli/<version> (...)`. A consumer that
matches on the old string (log parsing, a server allowlist keyed on the
literal user agent) needs to update that match.

## Hygiene identifier

The consumer-visible macro-hygiene identifier `chronosInternalRetFuture`
renames to `internalRetFuture`. This only matters to code that probes for
it directly (`when declared(chronosInternalRetFuture)` inside a macro
operating on `{.async.}`-generated code); ordinary `async`/`await` usage
never references it.

## Deliberate exception: `-d:chronosSimulation`

`-d:chronosSimulation` keeps its old spelling. The deterministic simulation
substrate it gates is fork-only test infrastructure scheduled for removal
once the dispatcher port work lands; renaming it now would mean renaming it
again at deletion, so it was left as-is. A `chronos` grep hit on this one
symbol is expected and is not an incomplete rename.

## Runtime identity strings

A handful of strings baked into the runtime for debugging and OS-level
namespacing also renamed, though none of these are part of the public API
surface a consumer calls directly:

- Future debug labels (the descriptive names attached to internally
  constructed futures, e.g. by `or`/`allFutures`/`wait`) now read
  `tonalli.<procName>(...)` instead of `chronos.<procName>(...)`.
- The Windows named-pipe prefix used for process I/O now reads
  `\\.\pipe\LOCAL\tonalli\` instead of the old `chronos`-prefixed path.
- The Windows signal-event namespace prefix now reads `Local\tonalli-events-`
  instead of the old `chronos`-prefixed name.

None of these are meant to be parsed by consumer code; they are listed here
only so a grep for the old strings in logs or process listings is not
mistaken for a leftover.

## Local environment note

A long-lived development container with persisted nimble package state can
keep resolving a stale `chronos` package after pulling this rename, rather
than failing loudly with a missing-import error. If a build behaves as
though it is still on the old name after updating source, refresh the local
nimble package cache and package list before assuming the rename itself is
incomplete.
