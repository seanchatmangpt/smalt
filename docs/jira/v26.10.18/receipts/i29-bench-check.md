# i29 bench-lane smoke (post-0009df3)

- Date: 2026-10-19 05:11 UTC
- Subject: /Users/sac/smalt @ 0009df32aac4e7d3836d246b8852e65ca8163cb2 (branch main, dirty tree — lane wrote only its own files)
Context: solo (single lane on the checkout; global substrate held by external ssh forward pid 61023, untouched)

## Verdict: PASS (lane b7) / bench-check gate FAIL (stale receipt, pre-existing)

### 1. `just bench-check` — FAIL (stale, not perf)

```
== Bench Gate ==
  receipt                       25.27 h  (<= 24.0) -> FAIL
Gate: FAIL (0/1 CTQs pass)
```

The only failing CTQ is receipt age (25.27h > 24h budget). Per the justfile note
("a stale-receipt bench-check failure is remediated by `just bench`, never by
touching the gate"), refresh requires `just bench`, which needs the global
ports 9443/8443/5672 — all held by an external ssh forward (pid 61023, not this
lane's process). Eviction is prohibited by lane law, so the refresh is BLOCKED
this window. No perf CTQ regressed; the failure is staleness only.

### 2. Lightest registered lane: b7 (`scripts/bench/b7_store_beam.exs`)

Boot: `MIX_ENV=test mix run --no-start scripts/bench/b7_store_beam.exs`
(BEAM-native, no ports used; b7 block 39070..39075 verified free by lsof
pre-flight). Exit 0, errors 0 across all ops.

`just bench-machine`:
`{"cpu":"Apple M3 Max","cores":16,"ram_gb":48,"elixir":"1.19.5","otp":"28","darwin":"26.2"}`

Result file (5 rows appended):
`/Users/sac/smalt/docs/jira/v26.10.18/bench/b7-store-beam.jsonl`

```
{"lane":"b7","op":"put","n":120000,"ops_per_sec":368056,"p50_ms":0.001,"p95_ms":0.002,"p99_ms":0.004,"errors":0}
{"lane":"b7","op":"get","n":120000,"ops_per_sec":1362212,"p50_ms":0.001,"p95_ms":0.002,"p99_ms":0.002,"errors":0}
{"lane":"b7","op":"compare_and_swap","n":120000,"ops_per_sec":135634,"p50_ms":0.004,"p95_ms":0.005,"p99_ms":0.008,"errors":0}
{"lane":"b7","op":"concurrent_put_get_32p","n":512000,"ops_per_sec":1326652,"errors":0}
{"lane":"b7","op":"list_prefix_10k","n":10000,"ops_per_sec":1451379,"full_scan_ms":6.890,"errors":0}
```

Also witnessed clean: `insert_new_race_64` 20/20 rounds with exactly
1 winner / 63 losers (single-writer-wins invariant holds under contention).

## Standing

- Lane b7 smoke: **ALIVE** (exit 0, 0 errors, plausible numbers on M3 Max).
- `just bench-check`: **SUSPECT (stale receipt)** — pre-existing condition,
  remediation (`just bench`) blocked by externally-held ports, not by a
  perf regression.

## Falsifier / replay

```
MIX_ENV=test mix run --no-start scripts/bench/b7_store_beam.exs   # exit 0
just bench-check                                                  # exits 1 until `just bench` refreshes tmp/bench-receipt.json
```

Lane constraints honored: no edits to shared infra, no git ops, no port kills,
no _build deletion. Aged global test profile reused (`_build/test`); no new
lane build root created.
