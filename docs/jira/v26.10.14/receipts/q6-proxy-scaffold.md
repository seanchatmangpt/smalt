# Receipt — Q-6: WO-23 substrate proxy scaffold

- **Subject:** standalone `proxy/` mix project at `/Users/sac/smalt/proxy`
- **WO:** docs/jira/v26.10.15/23-substrate-proxy.md (scaffold slice only —
  real substrate dispatch is a documented stub)
- **Date:** 2026-10-15
- **Standing:** ALIVE (scaffold) — compile + tests witnessed below; forwarding,
  `/metadata/endpoints`, and substrate.sh repoint remain UNKNOWN (owned by
  later v26.10.15 lanes)

## Commands + exits

```
$ cd /Users/sac/smalt/proxy && mix compile
Compiling 3 files (.ex)
Generated smalt_proxy app
exit 0

$ cd /Users/sac/smalt/proxy && mix test
7 tests, 0 failures   (Finished in 0.05s)
exit 0
```

## Isolation proof (zero coupling)

- `proxy/` has its own `mix.exs` (app `:smalt_proxy`, deps: []) — not an
  umbrella child; root compile never touches it by construction.
- `git status --porcelain` this window: only new untracked files under
  `proxy/`; NO edits to root `mix.exs`, `lib/`, `Justfile`, `justfile.d/`,
  no umbrella children list touched.
- Root `mix compile` re-run after scaffold: exit 0.
- No `_build-*` lane build roots created; proxy uses its own `proxy/_build`.

## Files created (all new, absolute paths)

- /Users/sac/smalt/proxy/mix.exs
- /Users/sac/smalt/proxy/lib/smalt_proxy/application.ex
- /Users/sac/smalt/proxy/lib/smalt_proxy/router.ex
- /Users/sac/smalt/proxy/lib/smalt_proxy/namespace.ex
- /Users/sac/smalt/proxy/test/smalt_proxy_test.exs
- /Users/sac/smalt/proxy/test/test_helper.exs
- /Users/sac/smalt/proxy/README.md

## What the scaffold contains

- `SmaltProxy.Namespace` — prefix algebra: `<lane> ::= [a-z0-9]{1,8}`,
  `prefix = "s<lane>-"`, `stamp/2`, `scan_bound/1` (prefix <> 0xFF, matching
  `Smalt.Store.list_prefix/2` bounded-scan composition), `owns?/2`,
  `disjoint?/2`. Property tests (seeded, 500 iters, dependency-free — no
  stream_data, no mocks): grammar round-trip, invalid-lane refusals,
  stamp composition, cross-lane non-ownership, disjointness, scan-bound
  dominance.
- `SmaltProxy.Router` — GenServer-owned loopback listener, 127.0.0.1:9460
  only (`ip: {127,0,0,1}` in listen opts). Echo behavior witnessed by a real
  TCP connect/send/recv in the test. Acceptor + per-connection handler
  processes, 15s recv timeout.
- `SmaltProxy.Application` — one_for_one supervisor.

## Deferred (not in this slice, falsifiers for the wiring lanes)

- Real substrate forwarding dispatch — stub (README documents contract).
- `GET /metadata/endpoints` (WO-23 §5.1).
- substrate.sh flock/orphan deletion + repoint (§3.5) — no shared file
  touched this window.
- F1/F2/F3 falsifier runs (§4) — 20-lane wave, crash-isolation witness.

## Replay

```
cd /Users/sac/smalt/proxy && mix compile && mix test
cd /Users/sac/smalt && mix compile   # root isolation witness
```
