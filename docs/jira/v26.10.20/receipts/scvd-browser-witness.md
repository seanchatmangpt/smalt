# scvd-browser-witness — S4, Tier-1 in-browser witness (popcorn_demo)

**Standing:** PARTIAL_ALIVE (mixed: Tier-1 boot budget FAIL at current bundle size; one leg FAIL; Concurrency witness [SKIP])

Context: solo. Date: 2026-10-21T04:51Z (local 2026-10-20 ~21:51 PDT). Lane: S4 witness-only,
repo /Users/sac/smalt. Substrate: UP (during runs pid 62236; restarted externally to pid 37113
mid-window — lanes other than mine own substrate transitions; ports 9443/9444/5672/5673 all
LISTEN before and after). Machine: darwin 25.2.0, arm64, single host — popcorn_demo-local
measurement, not a `just bench-machine` farm report.

## What ran

`node scripts/browser_smoke.mjs` ×3 from `popcorn_demo/`, headless Chromium
(chrome-headless-shell), WASM BEAM booted in-page, SMOKE_RECEIPT read from `#status`.

## [SKIP] typed — Concurrency in-bundle ramp

Bounded poll (60s × 15 = 15 min, 2026-10-20 21:36–21:52 PDT) for
`lib/popcorn_demo/concurrency.ex` (S1's module) + re-cooked bundle
(`public/out/otp/manifest.json` mtime > module mtime): 15/15 iterations "module not
landed"; deadline expired with manifest unchanged (mtime 2026-10-20 21:18:17, predating
the poll). The bundle's Concurrency module is not JS-callable and never arrived in-bundle.
**In-actor concurrency ramp: NOT witnessed, not claimed.** Typed next-step: land
`concurrency.ex`, re-cook, then an in-bundle ramp harness (page-evaluatable counters),
never asserted from host-side numbers.

## Tier-1 boot budget — FAIL at current bundle (honest verdict)

| run | boot_ms | legs_rendered | poll_deltas_ms | exit |
|-----|---------|---------------|----------------|------|
| 1 | 601.66 | 22 | 201.6 / 199.47 / 200.5 | 1 |
| 2 | 601.18 | 22 | 201.8 / 199.28 / 200 | 1 |
| 3 | 601.00 | 22 | 201.34 / 199.37 / 200.19 | 1 |

PRD Tier-1 target < 500 ms: **FAIL** — all three rows 601.0–601.66 ms. This supersedes
the earlier 402 ms PASS witness: the bundle has since grown 4→18→22 legs and boot cost
moved 402→601 ms (ratio vs the fenced 18-leg baseline 402.88 ms = 1.492x — inside the
1.5x BENCH_BROWSER ratio fence by 0.008, outside the absolute Tier-1 budget). Poll
deltas remain ~200 ms (healthy, timer not degraded). The 1.492x row shows the fence is
one bundle-growth step away from breaching too.

## Leg verdicts (all 3 runs, exit=1)

- kv=FAIL(challenge:{:challenge_tcp_connect, :eprotonosupport}) — the one FAIL; raw
  TCP to the 8443 data plane is unavailable from the WASM transport. A lane with
  errors says so: **3/3 runs failed the smoke gate exit code.**
- OK legs (consistent ×3): cosmos_sql, sb_rule, registry, cas, containers, lifecycle,
  live, matrix(6-matched), param, rg, rules, tags.
- SKIP-class (loud): blob(cors-preflight-403), certs/eg/mcp/policy/queue(wasm-transport),
  eh(eh-plane-down), tls(ca-missing — host CA path unreadable from browser context;
  `/Users/sac/smalt/.smalt/tls/ca-cert.pem` exists on disk).

## Receipt chain

- Raw rows: session console output above (BROWSER_LEG_ROW / BROWSER_MEM_ROW /
  SMOKE_RECEIPT verbatim); browser-mem row SecurityError on measureUserAgentSpecificMemory
  (COOP/COEP present, but crossOriginIsolated measurement path not available in
  headless shell — not chased further in this lane).
- Prior witness: `popcorn_demo/BENCH_BROWSER.md` (402 ms era, exit=0 at 4/20 legs).
- Result jsonl: none emitted by this lane (witness-only, file ownership limited to this
  receipt).

## Falsifier

Any rerun after a re-cook showing boot_ms < 500 ms with exit=0 and kv not FAIL
invalidates the FAIL verdict; the [SKIP] Concurrency row closes only on an in-bundle
ramp receipt with per-poll counters emitted from inside the actor.
