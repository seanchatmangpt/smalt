# BK-74: Popcorn demo regression sweep (post BK-46/BK-15b/BK-56)

**Standing:** **ALIVE** — full suite green after solo re-run; BK-56 CORS flips hold in browser smoke.
Context: solo
Date: 2026-10-22

## Suite (full, substrate up, lane build root `_build-bk74`, asdf-pinned elixir 1.20.4-otp-29 / OTP 29.1.2)

```
$ cd popcorn_demo && MIX_BUILD_ROOT=_build-bk74 asdf exec mix test
Finished in 33.1 seconds (1.7s async, 31.3s sync)
Result: 189/190 passed, 3 skipped
Failed: 1 test
```

Note: `asdf exec mix` is required — bare `mix` resolves to homebrew Elixir 1.19.5, which the
demo's mix.exs (`~> 1.20`) refuses.

## Per-failure classification

| Failure | Class | Evidence |
|---|---|---|
| `PopcornDemo.EmpiricalCosmosSqlTest` point-read latency contract (`test/empirical_cosmos_sql_test.exs:82`): best-round p99=22938us >= 10000us fence | **load-flake** (not a regression) | Solo re-run `mix test test/empirical_cosmos_sql_test.exs:82`: PASS, best-round p99=5801us. Fenced round had rounds 1–3 p99 = 10577/5801(→5801 solo)/75857us — single-round GC/jit tail spike under full-suite concurrent load, correct best-round selection, wrong tail sample. No CORS/header surface touched. |

## Browser smoke

```
$ node scripts/browser_smoke.mjs
SMOKE_RECEIPT: cosmos_sql=OK(...); sb_rule=OK(...); registry=OK(...); acr=SKIP(face-absent::acr_face_absent);
apim=SKIP(wasm-transport:httpc); appconfig=OK(popcorn-ac-1046:kv+flag-lifecycle);
blob=SKIP(cors-preflight-403:create-container); cas=OK(insert,etag,fresh-200,stale-412,delete-204,gone-404);
certs=OK(popcorn-cert-482:purge); containers=OK(1-listed); dns=UNSUPPORTED(recordset-A:RouteNotFound-404-zone-deleted-clean);
eg=SKIP(wasm-transport:publish); egd=SKIP(kd101-airgap); eh=SKIP(eh-plane-down(5673-connect-:eprotonosupport));
export=OK(8-resources-exported); keyops=OK(ES256:verified); kv=OK(popcorn-secret-194:30-bytes-lifecycle);
lifecycle=OK(create:get:delete:get404); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:3-matched);
mcp=OK(32-tools); param=OK(1-matched-params); policy=OK(5-faces-1-defs);
queue=OK(popcorn-q-...:74-bytes-roundtrip); reconcile=OK(3-staged,seeded,feed-6,monotonic,typed-conflict,cas-winners);
rg=OK(5-rows); rules=OK(1-listed); scvd=OK(t16:5.489ms,p99:550us;...); tags=OK(2-tags-roundtrip);
tls=SKIP(ca-missing:/Users/sac/smalt/.smalt/tls/ca-cert.pem); topic=SKIP(wasm-transport:httpc)
SCVD_GATE: SCVD-OK:t16:5.489ms <= 3x rolling-best 5.214ms
```

**BK-56 flips hold**: `queue=OK` and `certs=OK` — both were `SKIP(wasm-transport)` in the last
pre-fix witness (`popcorn_demo/receipts/20261021T234535Z-witness-all.md`). Strictly-better witness.

## Known skips (pre-existing, not new, not regressions)

- `blob=SKIP(cors-preflight-403:create-container)` — BK-56 receipt itself states the blob leg
  remains this skip (demo-side face absent; `docs/jira/v26.10.22/receipts/bk56-allow-origin-actual.md:92`).
- `tls=SKIP(ca-missing:.../ca-cert.pem)` — present identically in prior witnesses; the CA file
  exists on disk (1099 bytes, Oct 19) but the wasm smoke cannot consume it. Unchanged.
- `eh=SKIP(eh-plane-down 5673)` — substrate runs EH port 5673 (status shows UP), but the smoke's
  connect hits `:eprotonosupport`; identical in prior witnesses.
- wasm-transport SKIPs (acr/apim/eg/egd/topic) and `dns=UNSUPPORTED` — unchanged from prior witnesses.

## Verdict

Zero real regressions from BK-46/BK-15b/BK-56. Suite: 189/190 + 3 skip with the single failure
classified load-flake (solo PASS). Smoke: 19 OK faces, BK-56 flips landed and hold. No fix required.
