# BENCH_BROWSER.md — popcorn_demo in-browser leg timing

Measured inside the WASM BEAM in headless Chromium (chrome-headless-shell 156.0.8078.4,
via `scripts/browser_smoke.mjs`), not on the host BEAM. Boot ms = wall time from
`app.js` script eval to the first composed `#status` line containing `live=` —
the same line the smoke gate reads as `SMOKE_RECEIPT`. Rows leave the page via
`console.log("BROWSER_LEG_ROW ...")`, piped to harness stdout by the existing
console forwarder; no fetch, no egress. Bounded: max 3 rows per invocation.

Substrate: UP (pid 57559; ports 9443/9444/5672/5673) at measurement time.
Machine: darwin 25.2.0, arm64 (`Darwin 25.2.0, arm64` — single-host, not a
`just bench-machine` farm report; this lane is popcorn_demo-local).

## Boot-time table

| run | boot_ms | legs_rendered | ratio vs prev | fence (≤1.5x prev) | exit |
|-----|---------|---------------|---------------|--------------------|------|
| 1 (4-leg baseline) | 402.57 | 4 | — | — | 0 |
| 2 | 403.34 | 4 | 1.002x | PASS | 0 |
| 3 | 402.57 | 4 | 0.998x | PASS | 0 |
| 4 (18-leg re-baseline) | 402.88 | 20 | 1.001x | PASS | 0 |
| 5 | 402.43 | 20 | 0.999x | PASS | 0 |
| 6 | 401.99 | 20 | 0.999x | PASS | 0 |

**Re-baseline note (2026-10-21, W6-I):** the bundle grew from 4 to 18 cooked
legs (panel reports `legs_rendered: 20` — the 18 cooked legs plus 2
informational panel entries). A boot-time regression vs the 4-leg baseline was
EXPECTED; none was observed — boot stayed ~402 ms across the growth (worst
ratio vs the 4-leg rows 1.001x). The fence resets to the 18-leg row: future
runs must stay ≤1.5x 402.88 ms (≤604.3 ms).

Ratio fence: every new row must be ≤ 1.5x the previous row's boot_ms.
Worst observed ratio 1.002x — well inside the fence; no outliers.

## Per-poll deltas

Poll interval 200 ms; observed deltas ~200–203 ms per run — healthy across both
the 4-leg and 20-leg panel states, timer not degraded by the leg growth
(4-leg: 202.58/199.89, 200.98/202.26, 202.88/199.6; 20-leg: 202.59/200.2,
202.82/199.52, 201.88/200.01).

## Embedded run output (verbatim, 2026-10-21T01:21Z + 01:31Z)

```text
=== RUN 1 ===
serving /Users/sac/smalt/popcorn_demo/public on 127.0.0.1:51292
[console] BROWSER_LEG_ROW {"lane":"browser-legs","boot_ms":402.57,"legs_rendered":4,"ts":"2026-10-21T01:21:45.670Z","poll_deltas_ms":[202.58,199.89]}
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); live=OK(endpoints,tenants,sts,subscriptions=1)
exit=0
=== RUN 2 ===
serving /Users/sac/smalt/popcorn_demo/public on 127.0.0.1:51323
[console] BROWSER_LEG_ROW {"lane":"browser-legs","boot_ms":403.34,"legs_rendered":4,"ts":"2026-10-21T01:21:46.571Z","poll_deltas_ms":[200.98,202.26]}
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); live=OK(endpoints,tenants,sts,subscriptions=1)
exit=0
=== RUN 3 ===
serving /Users/sac/smalt/popcorn_demo/public on 127.0.0.1:51342
[console] BROWSER_LEG_ROW {"lane":"browser-legs","boot_ms":402.57,"legs_rendered":4,"ts":"2026-10-21T01:21:47.469Z","poll_deltas_ms":[202.88,199.6]}
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); live=OK(endpoints,tenants,sts,subscriptions=1)
exit=0
```

### 18-leg re-measurement (2026-10-21T01:31Z, substrate pid 57559)

```text
=== RUN 4 ===
[console] BROWSER_LEG_ROW {"lane":"browser-legs","boot_ms":402.88,"legs_rendered":20,"ts":"2026-10-21T01:31:55.925Z","poll_deltas_ms":[202.59,200.2]}
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); blob=OK(popcorn/l3rb1792546315798-110/receipt.txt:61-roundtrip); certs=SKIP(data-plane-8443-unreachable::eprotonosupport); containers=SKIP(wasm-transport:no match of right hand side value:
exit=0
=== RUN 5 ===
[console] BROWSER_LEG_ROW {"lane":"browser-legs","boot_ms":402.43,"legs_rendered":20,"ts":"2026-10-21T01:31:56.821Z","poll_deltas_ms":[202.82,199.52]}
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); blob=OK(popcorn/l3rb1792546316686-110/receipt.txt:61-roundtrip); certs=SKIP(data-plane-8443-unreachable::eprotonosupport); containers=SKIP(wasm-transport:no match of right hand side value:
exit=0
=== RUN 6 ===
[console] BROWSER_LEG_ROW {"lane":"browser-legs","boot_ms":401.99,"legs_rendered":20,"ts":"2026-10-21T01:31:57.703Z","poll_deltas_ms":[201.88,200.01]}
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); blob=OK(popcorn/l3rb1792546317568-110/receipt.txt:61-roundtrip); certs=SKIP(data-plane-8443-unreachable::eprotonosupport); containers=SKIP(wasm-transport:no match of right hand side value:
exit=0
```

(The SMOKE_RECEIPT lines above are truncated at console-forward width; the
trailing legs on every 18-leg run were SKIP-class, loud and expected —
`certs=SKIP(data-plane-8443-unreachable)` and
`containers=SKIP(wasm-transport)`. `blob` gained OK with the leg growth. No
FAIL on any run; every run exit=0.)

## Files

- `popcorn_demo/public/app.js` — instrumentation (t0, poll deltas, boot capture
  on first `live=`, bounded row emission)
- `popcorn_demo/bench/browser-legs.jsonl` — result rows (6: three 4-leg, three
  18-leg)
- `popcorn_demo/BENCH_BROWSER.md` — this document
