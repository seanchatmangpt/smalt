# Receipt — popcorn_demo LiveBlob (lane L3)

**Standing:** **ALIVE** (host-side, real HTTP against the live substrate;
browser leg gated, see cross-origin verdict)

## Files

- `/Users/sac/smalt/popcorn_demo/lib/popcorn_demo/live_blob.ex` — 318 lines,
  exports `run/0` only, no supervision-tree wiring. Disjoint-files contract
  held: no other file touched.

## Wire truth established first (curl, before the module existed)

Substrate: `curl -s http://127.0.0.1:8443/healthz` → `{"status":"ready",...}`.

- Tokenless blob requests → `401 AuthenticationFailed MissingBearerToken`
  (enforce mode).
- STS lives on the control plane: `POST http://127.0.0.1:9443/smalt-tenant/oauth2/v2.0/token`
  (the 8443 plane has the route as auth-exempt but no handler — RouteNotFound).
- Blob PUT/GET require `x-ms-version` or a SAS/allowlisted host, else
  `400 MissingXMsVersion`.
- Full curl round-trip: create 201 / put 201 / get 200, `cmp` BYTES-EQUAL.

## Real host-side run (the gate)

Toolchain: asdf Elixir 1.20.4-otp-29 (popcorn_demo pins `~> 1.20`);
`MIX_BUILD_ROOT=_build-lane3`.

```
$ MIX_BUILD_ROOT=_build-lane3 mix run -e 'IO.puts("FINAL=" <> inspect(PopcornDemo.LiveBlob.run()))'
FINAL={:ok, "blob=OK(popcorn/l3rb1792538513504/receipt.txt:61-roundtrip)"}
```

Three consecutive green runs (distinct run-unique containers):

```
WALK={:ok, "blob=OK(popcorn/l3rb1792538446578/receipt.txt:61-roundtrip)"}
WALK2={:ok, "blob=OK(popcorn/l3rb1792538452474/receipt.txt:452474...-roundtrip... 61-roundtrip)"}
FINAL={:ok, "blob=OK(popcorn/l3rb1792538513504/receipt.txt:61-roundtrip)"}
```

The 61 bytes are asserted byte-equal between the PUT payload and the GET body
in-module (`got == payload`), on the REAL stored bytes — no mocks, no
fixtures.

## Defects found and fixed in-module (all measured, not assumed)

1. `:httpc` is unusable under the popcorn_demo mix env: the inets beams
   loaded there crash `:httpc.request/5` with
   `UndefinedFunctionError: :http_util.timestamp/0 is undefined` while the
   identical call succeeds in plain `erl` (witnessed twice). Fix: the host
   transport is a minimal real HTTP/1.1 client over `:gen_tcp` (kernel, no
   inets), loopback-only enforced.
2. OTP 29 `:httpc` matches methods as LOWERCASE atoms
   (`?WITH_BODY = [post, put, patch, delete]`); an upcased `:GET` yields
   `{:error, :invalid_method}`. (Transport.Httpc's own 4-arg call passes its
   "method" into the PROFILE slot — it works by accident, GET-only.)
3. `Popcorn.JS.run!/2` IS loaded+exported on the host, so testing it to pick
   the browser transport misroutes host runs to `Popcorn.Fetch` → silent
   `:timeout`. The correct bridge signal is `Popcorn.JS.available?/0`
   (same signal live.ex uses).

## Cross-origin (browser) verdict

The blob plane answers OPTIONS preflight from STORED `<Cors>` service
properties only (w6ay BlobCors). With no rules stored for the account,
a fetch from `http://127.0.0.1:<other-port>` gets **403 on preflight** and
no `Access-Control-Allow-Origin` on actual responses — a cross-origin
browser walk is NOT allowed by default. Consequences designed into the
module: the browser leg rides `Popcorn.Fetch` and the receipt contract
carries `blob=SKIP(cors-preflight-403:...)` for the loud gate; host-side
`:gen_tcp` is CORS-blind and runs the real walk regardless (proven above).
No local `:crypto` is needed (token minted over the wire), so the wasm core
runtime's missing crypto does not gate this walk.

## Mid-walk defect found on the substrate (pre-existing, not fixed here)

The shared `popcorn/l3demo` container picked up a WORM legal hold between my
curl probe and the module run: PUT answered real
`409 ContainerLocked ... immutable WORM retention`. This is why the module
uses run-unique containers (`l3rb<ms>`). Flag for whoever owns the WORM
fence lane.

## Notes for integration

- Compile: `MIX_BUILD_ROOT=_build-lane3 mix compile` exit 0. Remaining
  warnings in live_blob.ex are type-system notes flagging the
  (intentionally retained, browser-leg-gating) `blob=SKIP` clause as
  unreachable on host. Pre-existing unrelated warning:
  `lib/smalt/sb_rules.ex:544` (vendored slice).
- Compile-freeze disclosure: none (I fixed nothing outside my file; the
  transient live_matrix.ex compile break during the session was a sibling
  lane's in-flight edit and recovered on its own).
- `_build-lane3` (popcorn_demo) is a lane lease for the coordinator to
  reclaim at integration.
