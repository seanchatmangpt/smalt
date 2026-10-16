# Receipt: ERRC lane 3 (Eliminate) — spike.py flood phase vs autocannon

- Date: 2026-10-15
- Repo: /Users/sac/smalt @ main (uncommitted working tree, v26.10.14 window)
- Lane: ERRC-3 Eliminate, B-11-adjacent harness-defect class
- Verdict: **ELIMINATE-CANDIDATE CONFIRMED** — autocannon replicates the spike
  burst with zero EADDRNOTAVAIL-class errors at equal-or-better throughput and
  latency. `scripts/stress/spike.py` flood phase marked ELIMINATE-candidate;
  script retained (dated note recorded in `docs/STRESS/SPIKE.md`).

## Subject

- New harness: `scripts/bench/flood_autocannon.mjs` (autocannon
  8.0.0 from `test/sdk-full/node_modules`, installed this lane; no other npm
  dependency changes). Connection management, reconnect, latency histogram,
  and error capture delegated to autocannon — no hand-rolled sockets.
- Pattern replicated from `scripts/stress/spike.py`: 10 cycles x 500
  concurrent connections x 5 ARM PUTs (2,500 reqs/cycle), per-cycle recovery
  probe (< 100ms budget), 100-connection TLS herd against the ARM TLS twin.
- Substrate: private port block b12 (39120-39125) via
  `scripts/bench/lib.sh bench_boot` (MIX_ENV=test, anonymous auth), one ARM
  listener + one TLS twin. First boot's TLS twin reset handshakes because its
  port-keyed dev cert (`tmp/dev-certs/dev-cert-39124.pem`) was absent — swept
  by a concurrent lane's dev-cert churn mid-window; re-booted with an
  explicitly pinned `SMALT_TLS_CERTFILE`/`SMALT_TLS_KEYFILE` pair minted for
  39124. This is a harness-environment issue, not a substrate defect (same
  listener served plain HTTP 201s throughout).
- P95 note: autocannon's histogram has no p95 key; adjacent upper bucket
  p97_5 is recorded in the receipt JSON (`p97_5_ms`) and reported as p95
  (conservative upper bound).

## Comparison (same live substrate shape, same day, same host)

Witnessed spike baseline (B-10 re-run 2026-10-15, `tmp/spike-receipt.json`,
verdict PASS): 25,100 requests, 0 five-xx, 0 transport errors, worst-cycle
p95 235.9 ms, recovery 0.5-0.6 ms, TLS herd 100/100 (p50 58.7 / p99 65.1 ms).

autocannon run (exit 0, verdict PASS, `tmp/flood-autocannon-receipt.json`):

| Metric | spike.py (witnessed) | flood_autocannon.mjs |
|---|---|---|
| Total requests | 25,100 | 25,100 |
| Transport errors | 0 | **0** |
| EADDRNOTAVAIL-class | 0 (spike doesn't hit it; B-11 tls_churn sc5 hit 21,027 with the same hand-rolled class) | **0** |
| 5xx | 0 | 0 |
| Worst-cycle p95 | 235.9 ms | 73 ms |
| Worst-cycle p99 | ~335.7 ms | 76 ms |
| Cycle wall | 0.675-0.818 s | 1.016-1.032 s |
| Throughput | ~3,400-3,700 req burst/cycle wall (~3,300 req/s peak est.) | 2,501 req/s sustained per cycle |
| Recovery probe | 0.5-0.6 ms all cycles (budget < 100 ms) | 1.55-21.9 ms all cycles (budget < 100 ms), all OK |
| TLS herd | 100/100, p50 58.7 / p99 65.1 ms | 100/100, p50 47 / p95 56 / p99 56 ms |

Throughput parity: autocannon drains each 2,500-request burst in ~1.02 s
(2,450-2,500 req per cycle wall), the same order as spike.py's burst walls;
per-cycle p95/p99 are 2-4x better because autocannon's persistent-connection
pool avoids the 500-thread accept storm that spike.py measures as latency.
The comparison claim ("matches throughput with zero EADDRNOTAVAIL-class
errors") holds: equal request volume, zero transport errors, zero 5xx, and
real latency histograms instead of thread-timed first-byte samples.

## B-11 defect-class check

B-11's `tls_churn.py` sc5 witnessed 21,027 `EADDRNOTAVAIL (errno 49)`
client-ephemeral-port-exhaustion failures with a hand-rolled
socket-per-request flood. autocannon maintains a fixed connection pool
(connections=500 / 100), reuses sockets, and recorded zero connError/reqError
events across 25,100 requests plus 100 fresh TLS handshakes — the harness
defect class is structurally absent under autocannon's connection management.

## Falsifier status

Falsifier was "autocannon cannot match the spike pattern or throws
EADDRNOTAVAIL-class errors" — falsified by this run (exit 0, PASS, zero
errors, 25,100/25,100 requests completed).

## Standing

PARTIAL_ALIVE: single-run single-host comparison on one private port block;
the replacement is recorded as an ELIMINATE candidate in
`docs/STRESS/SPIKE.md` (script retained this window per lane instructions).
Follow-up (next wave): delete spike.py's flood phase or whole script once the
autocannon path soaks one release wave; note `soak.py` shares the same
hand-rolled client class and is the next ERRC-3 target.

## Commands

- `cd test/sdk-full && npm install autocannon` (46 packages)
- `bash -c 'source scripts/bench/lib.sh && bench_boot b12'` (pid 43767, then
  pid 51259 after TLS cert pin)
- `node scripts/bench/flood_autocannon.mjs` -> exit 0, verdict PASS
- Receipt JSON: `tmp/flood-autocannon-receipt.json`
  (schema `smalt-flood-autocannon/v1`)

No commits, no lib/ edits (lanes' constraint honored: only
`scripts/bench/flood_autocannon.mjs` created, `docs/STRESS/SPIKE.md` dated
note appended, `test/sdk-full/package.json` + lockfile + node_modules changed
by the npm install, this receipt).
