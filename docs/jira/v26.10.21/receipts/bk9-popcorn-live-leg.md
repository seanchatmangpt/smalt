# BK-9: popcorn_demo live loopback leg (browser WASM BEAM → smalt 9443)

**Standing:** ALIVE (host-side leg witnessed live; browser e2e typed PENDING-DEMO-HOST, see §5)

Context: solo

## 1. Scope

Wire `popcorn_demo` to the live smalt loopback substrate: a new live leg
(`PopcornDemo.Live`) walks the lawful ARM auth path against
`http://127.0.0.1:9443` — exempt metadata/tenants probes, exempt STS mint,
Bearer-authed `/subscriptions` — and the composed SMOKE_RECEIPT line carries
the `live=` fragment. Host-side the leg runs through the real loopback-only
`:httpc` transport (`PopcornDemo.Transport.Httpc`); in-browser through
`Popcorn.Fetch`. No new deps.

## 2. Implementation state (found on disk, verified)

All four plan surfaces were found already implemented and committed
(c72e47c, 934d21a) on `main`; this session verified rather than re-authored:

| Plan step | Surface | State |
|---|---|---|
| 1. `lib/popcorn_demo/live.ex` | `PopcornDemo.Live.run/0` + `format/1` | present; walks endpoints → tenants (Jason) → STS → Bearer subscriptions; `live=OK(endpoints,tenants,sts,subscriptions=N)` / `live=FAIL(step:reason)` / `live=SKIP(substrate-down)` (econnrefused-tagged) |
| 2. `lib/popcorn_demo/application.ex` | `children_task/0` composes the `live` leg first into the SMOKE_RECEIPT | present |
| 3. `scripts/browser_smoke.mjs` | exit contract: `live=OK`→0, any `live=SKIP`→3 (`SMOKE_ALLOW_OFFLINE=1`→0 with SKIP visible), `live=FAIL`/any `=FAIL`→1; exit-3 supremacy over the SCVD gate | present |
| 4. `popcorn_demo/README.md` | "Live loopback leg (witnessed)" section + exit-code contract table + exit-3 supremacy + `SMOKE_ALLOW_OFFLINE` + preflight-OPTIONS-auth-exempt note | present |

## 3. Host-side verification (the mandatory verified part)

Toolchain pinned per IMPL-9 (`elixir 1.20.4-otp-29` + `erlang 29.1.2`
prepended to PATH; homebrew 1.19.5 shadow hazard applies to `just` recipes
too — substrate boot required the same PATH prefix).

Substrate: `just substrate-up` (lock fd closed) after clearing a stale
waiter; all four listeners UP (pid 53160), lock FREE.

```
$ cd popcorn_demo && MIX_BUILD_ROOT=_build-bk9 mix run -e \
  'IO.puts(PopcornDemo.Live.format(PopcornDemo.Live.run()))'
19:35:55.800 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)
```

Full host suite (substrate up, `_build-bk9`, then lane build root deleted at
integration per the cleanup law):

```
$ MIX_BUILD_ROOT=_build-bk9 mix test
Finished in 80.9 seconds (2.6s async, 78.2s sync)
Result: 188/190 passed, 3 skipped
Failed: 2 tests
```

The 2 failures are latency-fence tests
(`empirical_flag_latency_test.exs` p99=18631µs ≥ 5000µs fence) induced by
concurrent-lane compile load saturating the machine (round 1 p99=106391µs
under load vs round 3 p99=1339µs settled — the fence measures the machine,
not the stack). Isolated rerun:

```
$ MIX_BUILD_ROOT=_build-bk9 mix test test/empirical_flag_latency_test.exs test/empirical_kv_latency_test.exs
Result: 6 passed
```

Environment-dependence disclosed, not a regression of this leg. The pure leg
(SMOKE_RECEIPT smoke line: `cosmos_sql=OK(...); sb_rule=OK(...);
registry=OK(...)`) passed in every run, including a substrate-DOWN run that
returned 63 typed live-leg skips (`econnrefused`) with the pure leg green —
the pure leg is unchanged.

## 4. Live round-trip receipt

```
GET  http://127.0.0.1:9443/metadata/endpoints  → 200
GET  http://127.0.0.1:9443/tenants             → 200, tenantId 00000000-...-000000000000
POST /{tid}/oauth2/v2.0/token                  → 200 (client_credentials, any id/secret)
GET  /subscriptions?api-version=2022-12-01     → 200, Bearer accepted, 1 subscription
live=OK(endpoints,tenants,sts,subscriptions=1)
```

## 5. Browser e2e: PENDING-DEMO-HOST

`node scripts/browser_smoke.mjs` (cook + headless-Chromium wasm run) was not
executed this session: the demo host window is unavailable under the
concurrent-lane compile load, and the cook is expensive. Typed loudly as
PENDING-DEMO-HOST; the exit-3/`SMOKE_ALLOW_OFFLINE` contract is exercised by
the same gate when it runs. Host-side `live=OK` above is the ALIVE evidence
for the wire path; the browser leg differs only in transport
(`Popcorn.Fetch` vs `:httpc`).

## 6. Commands (replay)

```bash
export PATH="$HOME/.asdf/installs/elixir/1.20.4-otp-29/bin:$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH"
just substrate-up   # lock fd closed
cd popcorn_demo
MIX_BUILD_ROOT=_build-bk9 mix run -e 'IO.puts(PopcornDemo.Live.format(PopcornDemo.Live.run()))'
MIX_BUILD_ROOT=_build-bk9 mix test
```
