# BENCH_COOK — popcorn_demo cook + boot budget lane

Lane `cook` (script `scripts/bench_cook.sh`, results
`popcorn_demo/bench/cook.jsonl`). Times the two phases a popcorn_demo
contributor actually waits on:

| phase | command (from `popcorn_demo/`) | runs | notes |
|---|---|---|---|
| `cook` | `mix popcorn.cook --out-dir public/out` | 2 | pinned 29.0.6 / Elixir 1.20.4-otp-29 PATH per README |
| `boot` | `node scripts/browser_smoke.mjs` | 2 | end-to-end wasm-BEAM browser boot; real exit contract (0/1/3 per docs/TESTBED.md) preserved |

Row shape: `{"lane":"cook","phase":...,"median_ms":...,"runs":2,"runs_ms":[a,b],"ts":...,"errors":N}`
— both raw run values reported (`runs_ms`), median of the two. No sleeps; the
runs themselves are the observations. Substrate preflight on
`http://127.0.0.1:9443/metadata/endpoints` (BLOCKED exit 2 if down).

## Ratio fence (relative only — never absolute ms)

A phase REGRESSES if its median exceeds **1.5x the previous recorded median
for the same phase** in `bench/cook.jsonl` (row-to-row comparison; first
recording establishes the baseline and cannot fire). The gate compares
medians between jsonl rows, never a wall-clock constant.

Non-vacuity witnessed 2026-10-20: injecting a 10x cook row into a temp copy
fired `FENCE: cook median 26450ms > 1.5x prev 2716ms`, exit 1.

## Recorded baselines (2026-10-20, substrate UP, lane exit 0, errors 0)

| ts | phase | runs_ms | median_ms |
|---|---|---|---|
| 1792544216 | cook | [2780, 2510] | **2645** |
| 1792544216 | boot | [901, 906] | **904** |
| 1792544236 | cook | [2595, 2837] | **2716** |
| 1792544236 | boot | [916, 919] | **918** |

Working medians: cook ~2.6–2.7 s, boot ~0.9 s. Fence for the next recording:
cook > ~4.0 s and boot > ~1.35 s would trip (1.5x the latest row), subject to
whatever the next row's predecessor is at run time.

## Known environment factors

- Cook recompiles any touched `lib/` files before packaging; a mid-lane edit
  from a concurrent lane shows up as a cook error row (seen once, disclosed in
  the receipt — the owning lane fixed its file and the clean run followed).
- `boot` includes the blob-leg CORS `SKIP(cors-preflight-403)` observed on
  every run; it is a loud SKIP in the smoke receipt, not a boot failure.
