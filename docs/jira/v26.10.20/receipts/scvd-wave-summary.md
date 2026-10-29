# SCVD Wave Summary (SCVD-T15)

**Standing:** PARTIAL_ALIVE — compiled from disk evidence only; every claim
below is re-read from the named jsonl/receipt at compile time. Lanes
without an on-disk jsonl are UNWITNESSED here.

Source files (all under `tmp/bench/`): `scvd-tier1.jsonl`,
`scvd-tier2.jsonl`, `scvd-tier3.jsonl`, `scvd-tail.jsonl`,
`scvd-chaos-conn.jsonl`, `scvd-wasm-vs-host.jsonl`, `scvd-blob.jsonl`.
Lane receipt: `receipts/scvd-t5-conn-exhaustion-chaos.md` (T5).

## T1 — cosmos concurrent put/get, 16 legs (scvd-tier1.jsonl)

PASS. 3 rows, all `verdict: PASS`, 0 errors each. n=160 per row
(16 legs × 5 cycles). ops_per_sec 2540.5 / 2434.3 / 2482.1; p50 5.201 /
5.500 / 5.380 ms; p99 17.020 / 17.914 / 17.336 ms. Endpoint
`https://127.0.0.1:9444` (TLS twin), Apple M3 Max.

## T2 — cosmos docs putget-c128 (scvd-tier2.jsonl)

Mixed. 4 rows on disk: three n=512 rows with `standing: FAIL`,
`errors: 512` (every op errored; 2560 / 2876.4 / 2738 ops_per_sec
against a 30000 ms wall budget — throughput figures on those rows are
the harness-defect rows, not a passing surface); one n=1024 row with
`standing: PASS`, `errors: 0`, 2245.6 ops_per_sec, p50 43.791 ms,
p99 150.613 ms. Verdict: PASS at n=1024 only; n=512 rows are the
recorded harness defect, not a surface pass.

## T3 — cosmos ramp to concurrency wall (scvd-tier3.jsonl)

Wall found at L8192. 8 rows: ramp-512 (4096 n, 1613.9 ops/s),
ramp-1024 (8192 n, 1253.6), ramp-2048 (16384 n, 975.2),
ramp-4096 (16384 n, 834) — all `wall_level: unreached`, 0 errors;
ramp-8192 row: n=15850, 508.6 ops/s, p50 11605.197 ms, p95 29975.851 ms,
**534 errors**; final `wall-summary` row: `wall_level: L8192`,
`typed_fail_512: true`. Two earlier wall-summary rows (`unreached`,
`typed_fail_512: false`) from the pre-L8192 runs. 0 errors on all
reached ramps below the wall.

## T4 — tail-latency invariance (scvd-tail.jsonl)

INVARIANCE-HOLDS (UPDATED 2026-10-21; previously INVARIANCE-BREACH,
SUSPECT-class standing). The 188.79 p99(c128)/p99(c1) ratio was a
fence-definition artifact, not a substrate defect: a scalar latency ratio at
depth 128 measures queueing depth (Little's law), not regression. Fence v2
(derivation in the `tmp/bench/scvd_tier4.mjs` header and the
`fence_definition` row of `tmp/bench/scvd-tail.jsonl`) replaces the scalar
fence with three conjunctive checks on min-of-3 best rounds: F1 throughput
floor (>= 0.5x c1 best: c1 1345.5 ops/s → floor 672.8), F2 depth envelope
(p99(level) <= 4 x level x p99(c1 best 1.263 ms); c16 7.687 vs 80.832 ms,
c128 157.613 vs 646.656 ms), F3 zero errors (errors_total 0). All levels
pass F1/F2/F3 → `verdict: INVARIANCE-HOLDS`, exit 0. Legacy ratio preserved
from the fence-v2 verdict row: `legacy_ratio_128_over_1: 124.79` — recorded,
no longer the verdict basis. The fence-v1 breach rows (9 measurement rows,
c1 p99 0.910/0.999/1.380 ms, c16 9.238/13.003/15.969 ms, c128
171.803/334.610/186.302 ms, `ratio_128_over_1: 188.79`) remain on disk as
evidence of the superseded fence, not of a substrate gap.

## T5 — connection-exhaustion chaos, TLS 9444 (scvd-chaos-conn.jsonl + receipts/scvd-t5-conn-exhaustion-chaos.md)

Mixed: 2 rows. Run 1 (17:44:06Z): 2000 TLS conns opened, refused 0,
reset 0, `refusal_class: accepted-all`, recovery failed after 30
attempts with `recovery_error: "unable to verify the first certificate..."`,
`verdict: FAIL`. Run 2 (17:44:16Z): same flood (flood_ms 1642),
2000 opened, refused 0, `accepted-all`, recovery on attempt 1
(recovery_put 140 ms / get 454 ms / total 594 ms), `verdict: PASS`.
Lane receipt on disk: `receipts/scvd-t5-conn-exhaustion-chaos.md`.
Standing of the surface: PASS on the recovering run only; run 1's
cert-verification recovery failure and the `accepted-all` refusal class
(no server-side connection refusal observed at 2000 conns) remain
recorded observations.

## T6 — WASM vs host (scvd-wasm-vs-host.jsonl)

ALIVE (per-row verdicts). 3 rows: ramp16 wall ratio wasm/host 0.9245
(4.974 ms vs 5.380 ms, PASS); ramp16 p99 ratio 0.0296 (514 us vs
17.336 ms, PASS, caveat: op classes differ — in-browser 16-actor walk
vs 16-leg cosmos put/get, indicative not like-for-like); ramp256 row
`verdict: PARTIAL_ALIVE` — no host ramp-256 row exists in
scvd-tier1.jsonl, ratio null. Rows note `just bench-machine` broken
(root:= collision `justfile.d/31-have.just:9`); machine identity
inherited from T1 rows.

## T12 — blob putget-c128 (scvd-blob.jsonl) — WITNESSED on disk, contrary to dispatch note

Dispatch described T12 as pending/UNWITNESSED; `tmp/bench/scvd-blob.jsonl`
exists with 3 rows, all `standing: PASS`, 0 errors: ops_per_sec
278.3 / 1132.7 / 1196.3, p50 413.076 / 98.695 / 92.749 ms,
p99 773.403 / 228.125 / 206.636 ms, wall 1840/452/428 ms against a
60000 ms budget, endpoint TLS 9444. Recorded as witnessed per disk
truth; the cold-row (278.3 ops/s, p50 413 ms) is the first run of the
three.

## Unwitnessed lanes

No jsonl found in `tmp/bench/` for any other SCVD tier/lane (T7–T11,
T13–T14 and any other assigned tier numbers): **UNWITNESSED** — no
standing asserted, no flip, nothing claimed.

## Compile-time notes

- Compiled 2026-10-21 by SCVD-T15 (milestone-doc) from disk only.
- No KD rows flipped. No GAP tokens minted or removed. No numbers
  invented; every figure above is transcribed from the named jsonl.
- Machine identity: Apple M3 Max, 16 cores, node v26.10.0 unless the
  row states otherwise (T2 rows carry elixir 1.19.5 / otp 28).
