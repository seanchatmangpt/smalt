# PB1SDKFIX — PB-1 SDK leg ifMatchEtag→accessCondition repair + fresh sweep rerun

**Standing:** **ALIVE** — corrected-leg rerun shows `injection_failures=0` at all
11 contention points with real 412 conflicts on the wire; the
`IF-MATCH-IGNORED` divergence claim stays REFUTED per
`receipts/kdim-ifmatch-row.md`. Context: solo

## Change

`scripts/bench/pb1_cosmos_sdk.mjs` `settle/3`: all three `item.replace`
call sites swapped `{ ifMatchEtag: "…" }` →
`{ accessCondition: { type: "IfMatch", condition: etag } }` (the documented
@azure/cosmos 4.10.1 shape; `ifMatchEtag` is not an option in this SDK
version — zero occurrences in dist/typings, KD-IM). Also corrected the same
mis-shape at `scripts/bench/lifecycle_harness.mjs` hop 3 (benign there — it
replaces with the current etag so the unconditional replace succeeded anyway,
but the header was never on the wire). `scripts/bench/a2_cas_contention.mjs`
already used the correct `accessCondition` shape (untouched).

## Fresh sweep (2026-10-22, driver `bash scripts/bench/pb1_fond_sweep.sh`, exit 0)

Native leg unchanged (11/11 rows, 0 errors, 25.2k→10.8k ops/s across 0→100%
contention). SDK leg, corrected shape, @azure/cosmos 4.10.1 over TLS twin
39014, N=150/point, FANOUT=4:

```text
2026-10-22T11:36:51.785Z meta {"sdk":"4.10.1","node":"v26.10.0","endpoint":"https://127.0.0.1:39014"}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r0","contention_pct":0,"retries_forced":0,"n":150,"ops_per_sec":279.55,"p50_ms":3.56,"p95_ms":4.17,"p99_ms":4.61,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r1","contention_pct":10,"retries_forced":1,"n":150,"ops_per_sec":140.93,"p50_ms":5.001,"p95_ms":19.344,"p99_ms":31.019,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r2","contention_pct":20,"retries_forced":2,"n":150,"ops_per_sec":131.25,"p50_ms":7.587,"p95_ms":8.842,"p99_ms":10.805,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r3","contention_pct":30,"retries_forced":3,"n":150,"ops_per_sec":83,"p50_ms":10.957,"p95_ms":16.141,"p99_ms":32.081,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r4","contention_pct":40,"retries_forced":4,"n":150,"ops_per_sec":57.82,"p50_ms":13.807,"p95_ms":32.807,"p99_ms":85.337,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r5","contention_pct":50,"retries_forced":5,"n":150,"ops_per_sec":53.7,"p50_ms":17.153,"p95_ms":25.306,"p99_ms":61.155,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r6","contention_pct":60,"retries_forced":6,"n":150,"ops_per_sec":53.62,"p50_ms":16.064,"p95_ms":32.19,"p99_ms":68.12,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r7","contention_pct":70,"retries_forced":7,"n":150,"ops_per_sec":50.88,"p50_ms":17.912,"p95_ms":27.4,"p99_ms":39.871,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r8","contention_pct":80,"retries_forced":8,"n":150,"ops_per_sec":40.59,"p50_ms":20.787,"p95_ms":43.921,"p99_ms":86.965,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r9","contention_pct":90,"retries_forced":9,"n":150,"ops_per_sec":43.81,"p50_ms":21.002,"p95_ms":36.655,"p99_ms":41.408,"errors":0,"injection_failures":0}
PB1ROW {"lane":"pb1","surface":"cosmos-sdk-tls-twin","op":"settle_r10","contention_pct":100,"retries_forced":10,"n":150,"ops_per_sec":30.24,"p50_ms":29.18,"p95_ms":55.47,"p99_ms":73.985,"errors":0,"injection_failures":0}
PB1SDK-DONE conflicts=37400 unexpected_errors=0
rows: 22 -> tmp/bench/pb1-fond-sweep.jsonl
```

## Reading

- `injection_failures=0` everywhere (was 170/point at every contention ≥10%
  before the fix) — every stale-etag injection was refused 412 on the wire.
- conflicts=37400 = the forced stale-etag 412s actually observed (2100/point
  at ≥10%: 150 waves × FANOUT 4 × r retries), 0 unexpected errors.
- SDK p50 rises 3.56 → 29.2 ms with contention — the retry tax the bench was
  built to measure, now genuinely exercised.
- PB-1 falsifier line in `bk5-powlbench.md` (injection_failures=0 refutes the
  divergence) is SATISFIED; bk5 PB-1 section updated to point here.

## Replay

```bash
export PATH="$HOME/.asdf/shims:$PATH"; cd /Users/sac/smalt
bash scripts/bench/pb1_fond_sweep.sh   # exit 0; rows in tmp/bench/pb1-fond-sweep.jsonl
```
